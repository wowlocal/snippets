package com.khm.snippets.android

import com.khm.snippets.core.SnippetsAndroidCore
import org.json.JSONObject

class CoreBridge {
    fun canonicalize(library: String): String = value(SnippetsAndroidCore.canonicalizeLibrary(library))

    fun upsert(library: String, snippet: SnippetItem): String = value(
        SnippetsAndroidCore.upsertSnippet(
            library, snippet.id, snippet.name, snippet.keyword, snippet.content,
            tagsJSON(snippet.tags), snippet.isEnabled, snippet.isPinned))

    fun delete(library: String, id: String): String =
        value(SnippetsAndroidCore.deleteSnippet(library, id))

    fun search(library: String, query: String): String =
        value(SnippetsAndroidCore.searchLibrary(library, query))

    fun reconcile(
        library: String,
        base: String,
        records: String,
        keys: KeyBundle,
        deviceID: String,
    ): ReconcileResult {
        val response = value(
            SnippetsAndroidCore.reconcileLibrary(
                library, base, records, keys.key, keys.salt, keys.scopeID, deviceID))
        val payload = JSONObject(response)
        return ReconcileResult(
            library = payload.getString("library"),
            records = payload.getString("records"),
            offers = payload.getString("offers"),
            needsUserAttention = payload.getBoolean("needsUserAttention"))
    }

    private fun value(response: String): String {
        val objectValue = JSONObject(response)
        if (!objectValue.optBoolean("ok")) {
            throw CoreFailure(objectValue.optString("error", "operation_failed"))
        }
        return objectValue.getString("value")
    }
}

data class ReconcileResult(
    val library: String,
    val records: String,
    val offers: String,
    val needsUserAttention: Boolean,
)

class CoreFailure(val code: String) : Exception(code)
