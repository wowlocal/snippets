package com.khm.snippets.android

import org.json.JSONArray
import org.json.JSONObject

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
    NEEDS_TRUSTED_DEVICE_OR_RECOVERY,
    WAITING_FOR_APPROVAL,
    APPROVAL_READY,
    RECOVERY_AUTH_REQUIRED,
    RECOVERY_KIT_LOCKED,
}

data class CloudConfiguration(
    val provider: SyncProvider = SyncProvider.DEVICE,
    val serverURL: String = "",
    val accessToken: String = "",
    val spaceID: String = "",
    val cursor: String? = null,
    val scopeBinding: String? = null,
    val datasetGeneration: String? = null,
    val feedEpoch: String? = null,
)

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
)

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
    .put("schemaVersion", 1)
    .put("provider", provider.name)
    .put("serverURL", serverURL)
    .put("accessToken", accessToken)
    .put("spaceID", spaceID)
    .put("cursor", cursor)
    .put("scopeBinding", scopeBinding)
    .put("datasetGeneration", datasetGeneration)
    .put("feedEpoch", feedEpoch)
    .toString()

fun cloudConfiguration(json: String): CloudConfiguration {
    val objectValue = JSONObject(json)
    return CloudConfiguration(
        provider = runCatching { SyncProvider.valueOf(objectValue.getString("provider")) }
            .getOrDefault(SyncProvider.DEVICE),
        serverURL = objectValue.optString("serverURL"),
        accessToken = objectValue.optString("accessToken"),
        spaceID = objectValue.optString("spaceID"),
        cursor = objectValue.optNullableString("cursor"),
        scopeBinding = objectValue.optNullableString("scopeBinding"),
        datasetGeneration = objectValue.optNullableString("datasetGeneration"),
        feedEpoch = objectValue.optNullableString("feedEpoch"),
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
