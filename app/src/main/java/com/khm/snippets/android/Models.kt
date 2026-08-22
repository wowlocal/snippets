package com.khm.snippets.android

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

data class SnippetItem(
    val id: String,
    val name: String,
    val keyword: String,
    val content: String,
    val tags: List<String>,
    val isEnabled: Boolean,
    val isPinned: Boolean,
)

enum class SyncProvider { DEVICE, SNIPPETS_CLOUD }

enum class CloudKeyStatus {
    SIGNED_OUT,
    READY,
    SETUP_INTERRUPTED,
    NEEDS_TRUSTED_DEVICE_OR_RECOVERY,
    WAITING_FOR_APPROVAL,
    APPROVAL_READY,
    RECOVERY_AUTH_REQUIRED,
    RECOVERY_KIT_LOCKED,
}

enum class CloudSetupStage {
    SIGNED_OUT,
    ACCOUNT_CONNECTED,
    LIBRARY_LOCKED,
    WAITING_FOR_APPROVAL,
    RECOVERY_KIT_NEEDS_VERIFICATION,
    SYNCING,
    UP_TO_DATE,
    NEEDS_ATTENTION,
}

data class CloudConfiguration(
    val provider: SyncProvider = SyncProvider.DEVICE,
    val serverURL: String = "",
    val apiBaseURL: String = "",
    val protocolMajor: Int = 0,
    val accessToken: String = "",
    val spaceID: String = "",
    val serverInstanceID: String? = null,
    val cursor: String? = null,
    val scopeBinding: String? = null,
    val datasetGeneration: String? = null,
    val feedEpoch: String? = null,
    val lastSuccessfulSyncEpochSeconds: Long? = null,
    /**
     * The selected library state is durable, but the staged OAuth session has not
     * necessarily replaced the active session yet. Startup completes this commit
     * before allowing the cloud data plane to run.
     */
    val pendingAuthorizationCommit: Boolean = false,
)

internal fun CloudConfiguration.requiresServerInstanceReview(): Boolean =
    protocolMajor == 2 && serverURL.isNotBlank() && spaceID.isNotBlank() &&
        serverInstanceID == null

data class KeyBundle(
    val key: String,
    val salt: String,
    val scopeID: String = "sync-v1",
)

data class CloudKeyBinding(
    val serverURL: String,
    val spaceID: String,
)

data class LibraryState(
    val snippets: List<SnippetItem> = emptyList(),
    val provider: SyncProvider = SyncProvider.DEVICE,
    val syncLabel: String = "On device",
    val isBusy: Boolean = false,
    val errorCode: String? = null,
    val cloudKeyStatus: CloudKeyStatus = CloudKeyStatus.SIGNED_OUT,
    val pairingQRCode: String? = null,
    val pairingConfirmationCode: String? = null,
    val approvalConfirmationCode: String? = null,
    val pairingExpiresAtEpochSeconds: Long? = null,
    val libraryID: String? = null,
    val libraryChoices: List<CloudLibraryChoice> = emptyList(),
    val librarySwitchFromID: String? = null,
    val recoveryKitStatus: RecoveryKitStatus = RecoveryKitStatus.NEVER_VERIFIED,
    val setupStage: CloudSetupStage = CloudSetupStage.SIGNED_OUT,
)

internal fun cloudStartupFailureState(
    base: LibraryState,
    loadedSnippets: List<SnippetItem>,
    errorCode: String,
): LibraryState = base.copy(
    snippets = loadedSnippets,
    isBusy = false,
    errorCode = errorCode,
    syncLabel = "Sync needs attention",
    setupStage = CloudSetupStage.NEEDS_ATTENTION,
)

enum class RecoveryKitStatus {
    NEVER_VERIFIED,
    VERIFIED_CURRENT,
    KNOWN_REPLACED,
    STATUS_UNCONFIRMED,
    REPLACEMENT_IN_PROGRESS,
}

data class CloudLibraryChoice(
    val spaceID: String,
    val serverInstanceID: String,
    val role: String,
    val scopeBinding: String,
) {
    val libraryID: String get() = cloudLibraryID(serverInstanceID, spaceID)
}

data class CloudStepUpBinding(
    val serverURL: String,
    val serverInstanceID: String,
    val spaceID: String,
    val scopeBinding: String,
) {
    fun matches(serverURL: String, resolution: HttpSyncClient.SpaceResolution): Boolean =
        this.serverURL == serverURL.trim().trimEnd('/') &&
            serverInstanceID.equals(resolution.serverInstanceID, ignoreCase = true) &&
            spaceID.equals(resolution.spaceID, ignoreCase = true) &&
            scopeBinding == resolution.scopeBinding && resolution.canWrite
}

enum class CloudPostAuthorizationOperation {
    SIGN_IN,
    CHANGE_ACCOUNT,
    CHANGE_LIBRARY,
    STEP_UP,
}

internal fun startupCloudKeyStatus(
    hasPendingPostAuthorization: Boolean,
    cloudSessionAvailable: Boolean,
    hasBoundKey: Boolean,
): CloudKeyStatus = when {
    hasPendingPostAuthorization -> CloudKeyStatus.SETUP_INTERRUPTED
    !cloudSessionAvailable -> CloudKeyStatus.SIGNED_OUT
    hasBoundKey -> CloudKeyStatus.READY
    else -> CloudKeyStatus.NEEDS_TRUSTED_DEVICE_OR_RECOVERY
}

internal data class PendingPostAuthorizationBootstrap(
    val serverURL: String,
    val serverInstanceID: String,
    val spaceID: String,
    val scopeBinding: String,
    val operation: CloudPostAuthorizationOperation,
) {
    fun matches(configuration: CloudConfiguration): Boolean =
        serverURL == configuration.serverURL.trim().trimEnd('/') &&
            serverInstanceID.equals(configuration.serverInstanceID, ignoreCase = true) &&
            spaceID.equals(configuration.spaceID, ignoreCase = true)

    fun matches(resolution: HttpSyncClient.SpaceResolution): Boolean =
        serverInstanceID.equals(resolution.serverInstanceID, ignoreCase = true) &&
            spaceID.equals(resolution.spaceID, ignoreCase = true) &&
            scopeBinding == resolution.scopeBinding && resolution.canWrite

    fun matches(binding: CloudStepUpBinding): Boolean =
        serverURL == binding.serverURL.trim().trimEnd('/') &&
            serverInstanceID.equals(binding.serverInstanceID, ignoreCase = true) &&
            spaceID.equals(binding.spaceID, ignoreCase = true) &&
            scopeBinding == binding.scopeBinding

    fun toJSON(): String = JSONObject()
        .put("schemaVersion", 1)
        .put("phase", "bootstrapPending")
        .put("serverURL", serverURL)
        .put("serverInstanceID", serverInstanceID)
        .put("spaceID", spaceID)
        .put("scopeBinding", scopeBinding)
        .put("operation", operation.name)
        .toString()

    companion object {
        fun fromJSON(raw: String): PendingPostAuthorizationBootstrap {
            val value = JSONObject(raw)
            require(value.keys().asSequence().toSet() == setOf(
                "schemaVersion", "phase", "serverURL", "serverInstanceID",
                "spaceID", "scopeBinding", "operation",
            ))
            require(value.getInt("schemaVersion") == 1)
            require(value.getString("phase") == "bootstrapPending")
            val serverURL = value.getString("serverURL").trim().trimEnd('/')
            require(serverURL.startsWith("https://"))
            val serverInstanceID = java.util.UUID.fromString(
                value.getString("serverInstanceID"),
            ).toString()
            val spaceID = java.util.UUID.fromString(value.getString("spaceID")).toString()
            val scopeBinding = value.getString("scopeBinding").also {
                require(it.toByteArray().size in 32..256)
            }
            return PendingPostAuthorizationBootstrap(
                serverURL = serverURL,
                serverInstanceID = serverInstanceID,
                spaceID = spaceID,
                scopeBinding = scopeBinding,
                operation = CloudPostAuthorizationOperation.valueOf(
                    value.getString("operation"),
                ),
            )
        }
    }
}

internal fun cloudLibraryID(serverInstanceID: String, spaceID: String): String {
    val source = "${serverInstanceID.lowercase()}:${spaceID.lowercase()}"
    return MessageDigest.getInstance("SHA-256")
        .digest(source.toByteArray(Charsets.UTF_8))
        .take(4)
        .joinToString("") { "%02X".format(it) }
}

internal data class RecoveryKitVerification(
    val serverURL: String,
    val spaceID: String,
    val keyEpoch: Int,
    val envelopeVersion: Int,
    val envelopeFingerprint: String,
    val kitFingerprint: String,
) {
    fun matchesCoordinates(configuration: CloudConfiguration): Boolean =
        serverURL == configuration.serverURL.trim().trimEnd('/') &&
            spaceID.equals(configuration.spaceID, ignoreCase = true)

    fun matches(
        configuration: CloudConfiguration,
        state: HttpSyncClient.RecoveryEnvelopeState,
    ): Boolean {
        val envelope = state.recovery ?: return false
        return matchesCoordinates(configuration) &&
            keyEpoch == state.keyEpoch &&
            keyEpoch == envelope.keyEpoch &&
            envelopeVersion == envelope.version &&
            envelopeFingerprint == fingerprint(envelope.ciphertext)
    }

    fun toJSON(): String = JSONObject()
        .put("schemaVersion", 2)
        .put("serverURL", serverURL)
        .put("spaceID", spaceID)
        .put("keyEpoch", keyEpoch)
        .put("envelopeVersion", envelopeVersion)
        .put("envelopeFingerprint", envelopeFingerprint)
        .put("kitFingerprint", kitFingerprint)
        .toString()

    companion object {
        fun fromRecoveryKit(
            kit: LibraryKeyBootstrap.RecoveryKit,
            envelope: HttpSyncClient.RecoveryEnvelopeRecord,
        ): RecoveryKitVerification =
            RecoveryKitVerification(
                serverURL = kit.serverURL.trim().trimEnd('/'),
                spaceID = kit.spaceID,
                keyEpoch = kit.keyEpoch,
                envelopeVersion = envelope.version,
                envelopeFingerprint = fingerprint(envelope.ciphertext),
                kitFingerprint = fingerprint(kit.toQRPayload().toByteArray(Charsets.UTF_8)),
            )

        fun fromJSON(raw: String): RecoveryKitVerification? = runCatching {
            val value = JSONObject(raw)
            // Schema 1 could identify only the library. It cannot prove that another
            // device has not replaced the envelope, so it deliberately fails closed.
            require(value.getInt("schemaVersion") == 2)
            RecoveryKitVerification(
                serverURL = value.getString("serverURL").trim().trimEnd('/'),
                spaceID = value.getString("spaceID"),
                keyEpoch = value.getInt("keyEpoch"),
                envelopeVersion = value.getInt("envelopeVersion"),
                envelopeFingerprint = value.getString("envelopeFingerprint"),
                kitFingerprint = value.getString("kitFingerprint"),
            ).also {
                require(it.serverURL.startsWith("https://"))
                require(it.spaceID.isNotBlank())
                require(it.keyEpoch > 0)
                require(it.envelopeVersion > 0)
                require(it.envelopeFingerprint.matches(Regex("^[0-9a-f]{64}$")))
                require(it.kitFingerprint.matches(Regex("^[0-9a-f]{64}$")))
            }
        }.getOrNull()

        private fun fingerprint(value: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(value)
                .joinToString("") { "%02x".format(it) }
    }
}

internal data class RecoveryKitVerificationState(
    val status: RecoveryKitStatus,
    val verification: RecoveryKitVerification? = null,
) {
    init {
        require(
            when (status) {
                RecoveryKitStatus.VERIFIED_CURRENT,
                RecoveryKitStatus.KNOWN_REPLACED,
                RecoveryKitStatus.STATUS_UNCONFIRMED -> verification != null
                RecoveryKitStatus.NEVER_VERIFIED,
                RecoveryKitStatus.REPLACEMENT_IN_PROGRESS -> verification == null
            },
        )
    }

    fun toJSON(): String = JSONObject()
        .put("schemaVersion", 3)
        .put("status", status.name)
        .put(
            "verification",
            verification?.let { JSONObject(it.toJSON()) } ?: JSONObject.NULL,
        )
        .toString()

    /** Never trust a prior-process positive result before a fresh server check. */
    fun loadedForDisplay(): RecoveryKitVerificationState =
        if (status == RecoveryKitStatus.VERIFIED_CURRENT) {
            copy(status = RecoveryKitStatus.STATUS_UNCONFIRMED)
        } else {
            this
        }

    companion object {
        val neverVerified = RecoveryKitVerificationState(RecoveryKitStatus.NEVER_VERIFIED)
        val replacementInProgress = RecoveryKitVerificationState(
            RecoveryKitStatus.REPLACEMENT_IN_PROGRESS,
        )

        fun fromJSON(raw: String): RecoveryKitVerificationState? = runCatching {
            val value = JSONObject(raw)
            when (value.getInt("schemaVersion")) {
                2 -> RecoveryKitVerificationState(
                    RecoveryKitStatus.STATUS_UNCONFIRMED,
                    requireNotNull(RecoveryKitVerification.fromJSON(raw)),
                )
                3 -> {
                    val status = RecoveryKitStatus.valueOf(value.getString("status"))
                    val verification = if (value.isNull("verification")) null else {
                        RecoveryKitVerification.fromJSON(
                            value.getJSONObject("verification").toString(),
                        )
                    }
                    RecoveryKitVerificationState(status, verification)
                }
                else -> error("unsupported recovery verification schema")
            }
        }.getOrNull()
    }
}

internal fun disconnectBlockedForRecovery(status: CloudKeyStatus): Boolean =
    status == CloudKeyStatus.RECOVERY_AUTH_REQUIRED ||
        status == CloudKeyStatus.RECOVERY_KIT_LOCKED ||
        status == CloudKeyStatus.SETUP_INTERRUPTED

internal fun disconnectBlockedForRecovery(status: RecoveryKitStatus): Boolean =
    status == RecoveryKitStatus.KNOWN_REPLACED ||
        status == RecoveryKitStatus.REPLACEMENT_IN_PROGRESS

internal const val RECOVERY_VERIFICATION_FILE = "recovery-verified.enc"

internal fun invalidateRecoveryVerification(store: EncryptedStore) {
    store.delete(RECOVERY_VERIFICATION_FILE)
}

internal fun storeRecoveryVerificationState(
    store: EncryptedStore,
    state: RecoveryKitVerificationState,
) {
    store.write(RECOVERY_VERIFICATION_FILE, state.toJSON())
}

/** A one-screen value. It must never be placed in LibraryState or saved by Compose. */
internal data class RecoveryKitPresentation(
    val qrPayload: String,
    val longCode: String,
)

internal data class CloudSignInCompletion(
    val succeeded: Boolean,
    val recoveryKit: RecoveryKitPresentation? = null,
)

fun parseLibrary(json: String): List<SnippetItem> {
    val array = JSONArray(json)
    return (0 until array.length()).map { index ->
        val item = array.getJSONObject(index)
        val tags = item.getJSONArray("tags")
        SnippetItem(
            id = item.getString("id"),
            name = item.getString("name"),
            keyword = item.getString("keyword"),
            content = item.getString("content"),
            tags = (0 until tags.length()).map(tags::getString),
            isEnabled = item.getBoolean("isEnabled"),
            isPinned = item.getBoolean("isPinned"),
        )
    }
}

fun tagsJSON(tags: List<String>): String = JSONArray(tags).toString()

fun CloudConfiguration.toJSON(): String = JSONObject()
    .put("schemaVersion", 4)
    .put("provider", provider.name)
    .put("serverURL", serverURL)
    .put("apiBaseURL", apiBaseURL)
    .put("protocolMajor", protocolMajor)
    .put("accessToken", accessToken)
    .put("spaceID", spaceID)
    .put("serverInstanceID", serverInstanceID)
    .put("cursor", cursor)
    .put("scopeBinding", scopeBinding)
    .put("datasetGeneration", datasetGeneration)
    .put("feedEpoch", feedEpoch)
    .put("lastSuccessfulSyncEpochSeconds", lastSuccessfulSyncEpochSeconds)
    .put("pendingAuthorizationCommit", pendingAuthorizationCommit)
    .toString()

fun cloudConfiguration(json: String): CloudConfiguration {
    val objectValue = JSONObject(json)
    val schemaVersion = objectValue.optInt("schemaVersion", 1)
    val serverURL = objectValue.optString("serverURL")
    val apiBaseURL = objectValue.optString("apiBaseURL")
    val protocolMajor = objectValue.optInt("protocolMajor")
    val storedProvider = runCatching { SyncProvider.valueOf(objectValue.getString("provider")) }
        .getOrDefault(SyncProvider.DEVICE)
    // Schema 2 is kept readable so an existing v2 checkpoint can fail closed with
    // scope_review_required instead of being mistaken for an unsupported provider.
    val hasCurrentHTTPBinding = schemaVersion in 2..4 && protocolMajor == 2 &&
        apiBaseURL == serverURL.trimEnd('/') + "/v2"
    return CloudConfiguration(
        provider = if (storedProvider == SyncProvider.SNIPPETS_CLOUD && !hasCurrentHTTPBinding) {
            SyncProvider.DEVICE
        } else storedProvider,
        serverURL = serverURL,
        apiBaseURL = apiBaseURL,
        protocolMajor = protocolMajor,
        accessToken = objectValue.optString("accessToken"),
        spaceID = objectValue.optString("spaceID"),
        serverInstanceID = objectValue.optNullableString("serverInstanceID"),
        cursor = objectValue.optNullableString("cursor"),
        scopeBinding = objectValue.optNullableString("scopeBinding"),
        datasetGeneration = objectValue.optNullableString("datasetGeneration"),
        feedEpoch = objectValue.optNullableString("feedEpoch"),
        lastSuccessfulSyncEpochSeconds = objectValue.optNullableLong(
            "lastSuccessfulSyncEpochSeconds",
        ),
        pendingAuthorizationCommit = objectValue.optBoolean(
            "pendingAuthorizationCommit",
            false,
        ),
    )
}

fun KeyBundle.toJSON(): String = JSONObject()
    .put("schemaVersion", 1)
    .put("scopeID", scopeID)
    .put("key", key)
    .put("salt", salt)
    .toString()

fun keyBundle(json: String): KeyBundle {
    val value = JSONObject(json)
    require(value.optInt("schemaVersion", 1) == 1)
    return KeyBundle(
        key = value.getString("key"),
        salt = value.getString("salt"),
        scopeID = value.optString("scopeID", "sync-v1"),
    )
}

fun CloudKeyBinding.toJSON(): String = JSONObject()
    .put("schemaVersion", 1)
    .put("serverURL", serverURL)
    .put("spaceID", spaceID)
    .toString()

fun cloudKeyBinding(json: String): CloudKeyBinding {
    val value = JSONObject(json)
    require(value.getInt("schemaVersion") == 1)
    return CloudKeyBinding(value.getString("serverURL"), value.getString("spaceID"))
}

private fun JSONObject.optNullableString(name: String): String? =
    if (isNull(name)) null else optString(name).takeIf(String::isNotBlank)

private fun JSONObject.optNullableLong(name: String): Long? =
    if (!has(name) || isNull(name)) null else getLong(name)
