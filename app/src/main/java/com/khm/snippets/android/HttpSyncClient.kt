package com.khm.snippets.android

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder

class HttpSyncClient {
    data class PullResult(
        val records: String,
        val cursor: String,
        val scopeBinding: String,
        val datasetGeneration: String,
        val feedEpoch: String,
    )

    data class PushResult(val records: String, val hadConflict: Boolean)

    fun pull(configuration: CloudConfiguration, cachedRecords: String): PullResult {
        return try {
            pullPages(configuration, cachedRecords)
        } catch (failure: SyncFailure) {
            if (configuration.cursor == null || failure.code != "cursor_invalid") throw failure
            pullPages(configuration.copy(cursor = null), "[]")
        }
    }

    private fun pullPages(configuration: CloudConfiguration, cachedRecords: String): PullResult {
        requireConfiguration(configuration)
        var cursor = configuration.cursor
        var recordsByID = recordsByID(if (cursor == null) "[]" else cachedRecords)
        var lastScope: JSONObject? = null
        var firstPage = true

        while (true) {
            val query = buildString {
                append("?limit=50")
                cursor?.let { append("&cursor=").append(urlEncode(it)) }
            }
            val response = request(
                configuration, "GET",
                "v1/spaces/${configuration.spaceID}/changes$query")
            val page = JSONObject(response)
            validateScope(configuration, page)
            if (firstPage && page.getBoolean("fullSnapshot")) recordsByID = linkedMapOf()
            val pageRecords = page.getJSONArray("records")
            for (index in 0 until pageRecords.length()) {
                val wire = serverToSwiftRecord(pageRecords.getJSONObject(index))
                recordsByID[wire.getString("id")] = wire
            }
            cursor = page.getString("cursor")
            lastScope = page
            firstPage = false
            if (!page.getBoolean("hasMore")) break
        }

        val scope = requireNotNull(lastScope)
        return PullResult(
            records = recordsJSON(recordsByID.values),
            cursor = requireNotNull(cursor),
            scopeBinding = scope.getString("scopeBinding"),
            datasetGeneration = scope.getString("datasetGeneration"),
            feedEpoch = scope.getString("feedEpoch"))
    }

    fun push(
        configuration: CloudConfiguration,
        cachedRecords: String,
        offersJSON: String,
    ): PushResult {
        requireConfiguration(configuration)
        val recordsByID = recordsByID(cachedRecords)
        val offers = JSONArray(offersJSON)
        var hadConflict = false

        var offset = 0
        while (offset < offers.length()) {
            val count = minOf(50, offers.length() - offset)
            val items = JSONArray()
            val batch = ArrayList<JSONObject>(count)
            repeat(count) { relativeIndex ->
                val offer = offers.getJSONObject(offset + relativeIndex)
                batch += offer
                val expectedRecordVersion = recordVersion(offer)
                items.put(JSONObject()
                    .put("record", swiftToServerRecord(offer))
                    // The protocol requires this nullable member to be present.
                    // JSONObject.put(name, null) removes it instead of encoding null.
                    .put(
                        "expectedRecordVersion",
                        expectedRecordVersion ?: JSONObject.NULL))
            }

            val response = JSONObject(request(
                configuration, "POST",
                "v1/spaces/${configuration.spaceID}/records:batch",
                JSONObject().put("items", items).toString()))
            validateScope(configuration, response)
            val outcomes = response.getJSONArray("outcomes")
            check(outcomes.length() == batch.size)

            batch.forEachIndexed { index, offer ->
                val outcome = outcomes.getJSONObject(index)
                when (outcome.getString("kind")) {
                    "accepted" -> {
                        val accepted = JSONObject(offer.toString())
                        accepted.put(
                            "recordVersion",
                            swiftRecordVersion(outcome.getString("recordVersion")))
                        recordsByID[accepted.getString("id")] = accepted
                    }
                    "conflict" -> {
                        hadConflict = true
                        val authoritative = outcome.getJSONObject("authoritativeRecord")
                        val wire = serverToSwiftRecord(authoritative)
                        recordsByID[wire.getString("id")] = wire
                    }
                    "rejected" -> throw SyncFailure(
                        outcome.optString("errorCode", "record_rejected"))
                    else -> throw SyncFailure("invalid_batch_outcome")
                }
            }
            offset += count
        }

        return PushResult(recordsJSON(recordsByID.values), hadConflict)
    }

    private fun request(
        configuration: CloudConfiguration,
        method: String,
        path: String,
        body: String? = null,
    ): String {
        val base = validatedBaseURL(configuration.serverURL)
        val connection = base.resolve(path).toURL().openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.instanceFollowRedirects = false
        connection.setRequestProperty("Accept", "application/json")
        connection.setRequestProperty("Authorization", "Bearer ${configuration.accessToken}")
        connection.setRequestProperty("X-Snippets-Protocol", "1")
        if (body != null) {
            val bytes = body.toByteArray(Charsets.UTF_8)
            require(bytes.size <= MAX_RESPONSE_BYTES)
            connection.doOutput = true
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.use { it.write(bytes) }
        }

        val status = connection.responseCode
        val responseBytes = readBounded(
            if (status in 200..299) connection.inputStream else connection.errorStream)
        val response = responseBytes.toString(Charsets.UTF_8)
        if (status !in 200..299) {
            val code = runCatching { JSONObject(response).getString("code") }
                .getOrDefault("http_$status")
            throw SyncFailure(code)
        }
        return response
    }

    private fun validateScope(configuration: CloudConfiguration, value: JSONObject) {
        if (!value.getString("spaceId").equals(configuration.spaceID, ignoreCase = true)) {
            throw SyncFailure("invalid_scope_response")
        }
        fun mismatch(expected: String?, field: String): Boolean =
            expected != null && expected != value.getString(field)
        if (mismatch(configuration.scopeBinding, "scopeBinding") ||
            mismatch(configuration.datasetGeneration, "datasetGeneration") ||
            mismatch(configuration.feedEpoch, "feedEpoch")) {
            throw SyncFailure("scope_review_required")
        }
    }

    private fun serverToSwiftRecord(server: JSONObject): JSONObject = JSONObject()
        .put("id", server.getString("id"))
        .put("rev", server.getString("rev"))
        .put("deleted", server.getBoolean("deleted"))
        .put("blob", server.getString("blob"))
        .put("recordVersion", swiftRecordVersion(server.getString("recordVersion")))

    private fun swiftToServerRecord(swift: JSONObject): JSONObject = JSONObject()
        .put("id", swift.getString("id"))
        .put("rev", swift.getString("rev"))
        .put("deleted", swift.getBoolean("deleted"))
        .put("blob", swift.getString("blob"))

    private fun swiftRecordVersion(version: String): JSONObject = JSONObject()
        .put("schemaVersion", 1)
        .put("data", Base64.encodeToString(version.toByteArray(), Base64.NO_WRAP))

    private fun recordVersion(swift: JSONObject): String? {
        if (swift.isNull("recordVersion")) return null
        val encoded = swift.getJSONObject("recordVersion").getString("data")
        return Base64.decode(encoded, Base64.DEFAULT).toString(Charsets.UTF_8)
    }

    private fun recordsByID(recordsJSON: String): LinkedHashMap<String, JSONObject> {
        val result = linkedMapOf<String, JSONObject>()
        val records = JSONArray(recordsJSON)
        for (index in 0 until records.length()) {
            val value = records.getJSONObject(index)
            result[value.getString("id")] = value
        }
        return result
    }

    private fun recordsJSON(records: Collection<JSONObject>): String {
        val sorted = records.sortedBy { it.getString("id") }
        return JSONArray().also { array -> sorted.forEach(array::put) }.toString()
    }

    private fun validatedBaseURL(raw: String): URI {
        val uri = URI(raw.trim().trimEnd('/') + "/")
        require(uri.scheme == "https" && uri.host != null)
        require(uri.userInfo == null && uri.query == null && uri.fragment == null)
        return uri
    }

    private fun requireConfiguration(configuration: CloudConfiguration) {
        validatedBaseURL(configuration.serverURL)
        require(configuration.accessToken.length in 8..16_384)
        require(UUID_PATTERN.matches(configuration.spaceID))
    }

    private fun readBounded(input: java.io.InputStream?): ByteArray {
        requireNotNull(input)
        input.use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(16_384)
            var total = 0
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                total += count
                if (total > MAX_RESPONSE_BYTES) throw SyncFailure("response_too_large")
                output.write(buffer, 0, count)
            }
            return output.toByteArray()
        }
    }

    private fun urlEncode(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name())

    private companion object {
        const val MAX_RESPONSE_BYTES = 16 * 1024 * 1024
        val UUID_PATTERN = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}")
    }
}

class SyncFailure(val code: String) : Exception(code)
