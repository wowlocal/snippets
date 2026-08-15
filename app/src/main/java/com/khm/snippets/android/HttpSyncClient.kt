package com.khm.snippets.android

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.time.Instant
import java.util.UUID

class HttpSyncClient {
    data class PullResult(
        val records: String,
        val cursor: String,
        val scopeBinding: String,
        val datasetGeneration: String,
        val feedEpoch: String,
    )

    data class PushResult(val records: String, val hadConflict: Boolean)

    data class PairingRecord(
        val pairingID: String,
        val spaceID: String,
        val recipientPublicKey: ByteArray,
        val nonce: ByteArray,
        val authenticationTag: String,
        val state: String,
        val algorithm: String?,
        val ciphertext: ByteArray?,
        val expiresAtEpochSeconds: Long,
    )

    data class RecoveryEnvelopeRecord(
        val version: Int,
        val keyEpoch: Int,
        val algorithm: String,
        val ciphertext: ByteArray,
    )

    data class RecoveryEnvelopeState(
        val keyEpoch: Int,
        val recovery: RecoveryEnvelopeRecord?,
    )

    fun pull(
        configuration: CloudConfiguration,
        cachedRecords: String,
        accessToken: String = configuration.accessToken,
    ): PullResult {
        return try {
            pullPages(configuration, cachedRecords, accessToken)
        } catch (failure: SyncFailure) {
            if (configuration.cursor == null || failure.code != "cursor_invalid") throw failure
            pullPages(configuration.copy(cursor = null), "[]", accessToken)
        }
    }

    private fun pullPages(
        configuration: CloudConfiguration,
        cachedRecords: String,
        accessToken: String,
    ): PullResult {
        requireConfiguration(configuration, accessToken)
        var cursor = configuration.cursor
        var recordsByID = recordsByID(if (cursor == null) "[]" else cachedRecords)
        var lastScope: JSONObject? = null
        var firstPage = true

        while (true) {
            val query = buildString {
                // Ten maximum-size base64 blobs plus JSON metadata remain below the
                // client's 16 MiB response ceiling. The protocol permits 50, but a
                // valid all-conflict/full-snapshot response at that size does not.
                append("?limit=").append(MAX_RECORDS_PER_HTTP_MESSAGE)
                cursor?.let { append("&cursor=").append(urlEncode(it)) }
            }
            val response = request(
                configuration, "GET",
                "v1/spaces/${configuration.spaceID}/changes$query",
                accessToken = accessToken)
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
        accessToken: String = configuration.accessToken,
    ): PushResult {
        requireConfiguration(configuration, accessToken)
        val recordsByID = recordsByID(cachedRecords)
        val offers = JSONArray(offersJSON)
        var hadConflict = false

        var offset = 0
        while (offset < offers.length()) {
            // Bound both the request and a worst-case response containing an
            // authoritative maximum-size record for every conflict.
            val count = minOf(MAX_RECORDS_PER_HTTP_MESSAGE, offers.length() - offset)
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
                JSONObject().put("items", items).toString(),
                accessToken))
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
        accessToken: String = configuration.accessToken,
    ): String = request(
        serverURL = configuration.serverURL,
        accessToken = accessToken,
        method = method,
        path = path,
        body = body,
    )

    fun resolvePersonalSpace(
        serverURL: String,
        accessToken: String,
        existingSpaceID: String? = null,
    ): String {
        validatedBaseURL(serverURL)
        requireAccessToken(accessToken)
        val spaces = JSONObject(request(serverURL, accessToken, "GET", "v1/spaces"))
            .getJSONArray("spaces")
        val candidates = (0 until spaces.length()).map { spaces.getJSONObject(it) }
        existingSpaceID?.let { existing ->
            candidates.firstOrNull {
                it.getString("spaceId").equals(existing, ignoreCase = true)
            }?.let { return it.getString("spaceId") }
        }
        if (candidates.size == 1) return candidates.single().getString("spaceId")
        val owned = candidates.filter { it.optString("role") == "owner" }
        if (owned.size == 1) return owned.single().getString("spaceId")
        if (candidates.isNotEmpty()) throw SyncFailure("space_selection_required")

        val body = JSONObject().put("idempotencyKey", PERSONAL_SPACE_IDEMPOTENCY_KEY).toString()
        return JSONObject(request(serverURL, accessToken, "POST", "v1/spaces", body))
            .getString("spaceId")
    }

    fun createPairing(
        serverURL: String,
        spaceID: String,
        accessToken: String,
        draft: LibraryKeyBootstrap.PairingDraft,
        expiresInSeconds: Int = LibraryKeyBootstrap.DEFAULT_PAIRING_SECONDS,
    ): PairingRecord {
        require(expiresInSeconds in 60..600)
        val body = JSONObject()
            .put("recipientPublicKey", draft.recipientPublicKey.standardBase64())
            .put("nonce", draft.nonce.standardBase64())
            .put("expiresInSeconds", expiresInSeconds)
            .toString()
        return pairingRecord(JSONObject(request(
            serverURL,
            accessToken,
            "POST",
            "v1/spaces/${validatedUUID(spaceID)}/pairings",
            body,
        )))
    }

    fun pairing(
        serverURL: String,
        spaceID: String,
        pairingID: String,
        accessToken: String,
    ): PairingRecord = pairingRecord(JSONObject(request(
        serverURL,
        accessToken,
        "GET",
        "v1/spaces/${validatedUUID(spaceID)}/pairings/${validatedUUID(pairingID)}",
    )))

    fun approvePairing(
        serverURL: String,
        spaceID: String,
        pairingID: String,
        recipientPublicKey: ByteArray,
        ciphertext: ByteArray,
        accessToken: String,
    ): PairingRecord {
        val body = JSONObject()
            .put(
                "recipientKeyHash",
                LibraryKeyBootstrap.recipientKeyHash(recipientPublicKey).standardBase64(),
            )
            .put("algorithm", LibraryKeyBootstrap.PAIRING_ALGORITHM)
            .put("ciphertext", ciphertext.standardBase64())
            .toString()
        return pairingRecord(JSONObject(request(
            serverURL,
            accessToken,
            "PUT",
            "v1/spaces/${validatedUUID(spaceID)}/pairings/${validatedUUID(pairingID)}/approval",
            body,
        )))
    }

    fun takeApprovedPairing(
        serverURL: String,
        spaceID: String,
        pairingID: String,
        accessToken: String,
    ): PairingRecord = pairingRecord(JSONObject(request(
        serverURL,
        accessToken,
        "POST",
        "v1/spaces/${validatedUUID(spaceID)}/pairings/${validatedUUID(pairingID)}/consume",
    )))

    fun cancelPairing(
        serverURL: String,
        spaceID: String,
        pairingID: String,
        accessToken: String,
    ) {
        request(
            serverURL,
            accessToken,
            "DELETE",
            "v1/spaces/${validatedUUID(spaceID)}/pairings/${validatedUUID(pairingID)}",
        )
    }

    fun recoveryEnvelope(
        serverURL: String,
        spaceID: String,
        accessToken: String,
    ): RecoveryEnvelopeState {
        val value = JSONObject(request(
            serverURL,
            accessToken,
            "GET",
            "v1/spaces/${validatedUUID(spaceID)}/key-envelopes/current",
        ))
        val recovery = if (value.isNull("recovery")) null else {
            val envelope = value.getJSONObject("recovery")
            RecoveryEnvelopeRecord(
                version = envelope.getInt("version"),
                keyEpoch = envelope.getInt("keyEpoch"),
                algorithm = envelope.getString("algorithm"),
                ciphertext = envelope.getString("ciphertext").canonicalStandardBase64(4_096),
            )
        }
        return RecoveryEnvelopeState(value.getInt("keyEpoch"), recovery)
    }

    fun putRecoveryEnvelope(
        serverURL: String,
        spaceID: String,
        keyEpoch: Int,
        expectedVersion: Int?,
        ciphertext: ByteArray,
        accessToken: String,
    ): RecoveryEnvelopeRecord {
        val body = JSONObject()
            .put("expectedVersion", expectedVersion ?: JSONObject.NULL)
            .put("keyEpoch", keyEpoch)
            .put("algorithm", LibraryKeyBootstrap.RECOVERY_ALGORITHM)
            .put("ciphertext", ciphertext.standardBase64())
            .toString()
        val value = JSONObject(request(
            serverURL,
            accessToken,
            "PUT",
            "v1/spaces/${validatedUUID(spaceID)}/key-envelopes/recovery",
            body,
        ))
        return RecoveryEnvelopeRecord(
            version = value.getInt("version"),
            keyEpoch = value.getInt("keyEpoch"),
            algorithm = value.getString("algorithm"),
            ciphertext = value.getString("ciphertext").canonicalStandardBase64(4_096),
        )
    }

    fun hasRemoteRecords(serverURL: String, spaceID: String, accessToken: String): Boolean {
        val value = JSONObject(request(
            serverURL,
            accessToken,
            "GET",
            "v1/spaces/${validatedUUID(spaceID)}/changes?limit=1",
        ))
        return value.getJSONArray("records").length() > 0
    }

    private fun request(
        serverURL: String,
        accessToken: String,
        method: String,
        path: String,
        body: String? = null,
    ): String {
        val base = validatedBaseURL(serverURL)
        requireAccessToken(accessToken)
        val connection = base.resolve(path).toURL().openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.instanceFollowRedirects = false
        connection.setRequestProperty("Accept", "application/json")
        connection.setRequestProperty("Authorization", "Bearer $accessToken")
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

    private fun pairingRecord(value: JSONObject): PairingRecord {
        val publicKey = value.getString("recipientPublicKey").canonicalStandardBase64(65)
        val nonce = value.getString("nonce").canonicalStandardBase64(32)
        require(publicKey.size == 65 && publicKey.first() == 0x04.toByte())
        require(nonce.size == 32)
        val tag = value.getString("authenticationTag")
        require(tag.matches(Regex("[A-Z2-9]{8}")))
        val state = value.getString("state")
        require(state == "pending" || state == "approved")
        val algorithm = value.optString("algorithm").takeIf(String::isNotBlank)
        val ciphertext = value.optString("ciphertext").takeIf(String::isNotBlank)
            ?.canonicalStandardBase64(4_096)
        return PairingRecord(
            pairingID = validatedUUID(value.getString("pairingId")),
            spaceID = validatedUUID(value.getString("spaceId")),
            recipientPublicKey = publicKey,
            nonce = nonce,
            authenticationTag = tag,
            state = state,
            algorithm = algorithm,
            ciphertext = ciphertext,
            expiresAtEpochSeconds = Instant.parse(value.getString("expiresAt")).epochSecond,
        )
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

    private fun requireConfiguration(configuration: CloudConfiguration, accessToken: String) {
        validatedBaseURL(configuration.serverURL)
        requireAccessToken(accessToken)
        require(UUID_PATTERN.matches(configuration.spaceID))
    }

    private fun requireAccessToken(accessToken: String) {
        require(accessToken.length in 8..16_384 && accessToken.none(Char::isWhitespace))
    }

    private fun validatedUUID(value: String): String = UUID.fromString(value).toString().also {
        require(it.equals(value, ignoreCase = true))
    }

    private fun ByteArray.standardBase64(): String =
        Base64.encodeToString(this, Base64.NO_WRAP)

    private fun String.canonicalStandardBase64(maximumBytes: Int): ByteArray {
        require(length <= ((maximumBytes + 2) / 3) * 4)
        val decoded = Base64.decode(this, Base64.DEFAULT)
        require(decoded.size <= maximumBytes)
        require(Base64.encodeToString(decoded, Base64.NO_WRAP) == this)
        return decoded
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
        const val MAX_RECORDS_PER_HTTP_MESSAGE = 10
        const val MAX_RESPONSE_BYTES = 16 * 1024 * 1024
        const val PERSONAL_SPACE_IDEMPOTENCY_KEY = "7b28d156-77fd-4f7f-bdf3-234f7d97ac91"
        val UUID_PATTERN = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}")
    }
}

class SyncFailure(val code: String) : Exception(code)
