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
        val serverInstanceID: String,
        val scopeBinding: String,
        val datasetGeneration: String,
        val feedEpoch: String,
    )

    data class PushResult(
        val records: String,
        val hadConflict: Boolean,
        val feedEpoch: String,
    )

    data class SpaceResolution(
        val spaceID: String,
        val serverInstanceID: String,
        val role: String,
    ) {
        val canWrite: Boolean get() = role == "owner" || role == "writer"
    }

    data class SpaceCandidate(
        val spaceID: String,
        val serverInstanceID: String,
        val role: String,
    ) {
        val canWrite: Boolean get() = role == "owner" || role == "writer"
    }

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
                "v2/spaces/${configuration.spaceID}/changes$query",
                accessToken = accessToken)
            val page = JSONObject(response)
            val pageScope = page.getJSONObject("scope")
            validateScope(configuration, pageScope)
            if (firstPage && page.getBoolean("fullSnapshot")) recordsByID = linkedMapOf()
            val pageRecords = page.getJSONArray("records")
            for (index in 0 until pageRecords.length()) {
                val wire = serverToSwiftRecord(pageRecords.getJSONObject(index))
                recordsByID[wire.getString("id")] = wire
            }
            cursor = page.getString("cursor")
            lastScope = pageScope
            firstPage = false
            if (!page.getBoolean("hasMore")) break
        }

        val scope = requireNotNull(lastScope)
        return PullResult(
            records = recordsJSON(recordsByID.values),
            cursor = requireNotNull(cursor),
            serverInstanceID = scope.getString("serverInstanceId"),
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
        var feedEpoch = requireNotNull(configuration.feedEpoch)

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

            val expectedScope = JSONObject()
                .put("serverInstanceId", requireNotNull(configuration.serverInstanceID))
                .put("spaceId", configuration.spaceID)
                .put("scopeBinding", requireNotNull(configuration.scopeBinding))
                .put("datasetGeneration", requireNotNull(configuration.datasetGeneration))
                .put("feedEpoch", feedEpoch)
            val response = JSONObject(request(
                configuration, "POST",
                "v2/spaces/${configuration.spaceID}/records/batch",
                JSONObject()
                    .put("expectedScope", expectedScope)
                    .put("items", items)
                    .toString(),
                accessToken))
            val responseScope = response.getJSONObject("scope")
            // A successful mutation may atomically compact history and return a
            // newer feed. Account, membership, and dataset remain pinned; only the
            // cursor-maintenance epoch may advance between chunks.
            validateScope(configuration.copy(feedEpoch = null), responseScope)
            feedEpoch = validatedUUID(responseScope.getString("feedEpoch"))
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

        return PushResult(recordsJSON(recordsByID.values), hadConflict, feedEpoch)
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
    ): SpaceResolution {
        val candidates = personalSpaceCandidates(serverURL, accessToken)
        automaticPersonalSpace(candidates, existingSpaceID)?.let { return it }
        if (candidates.isNotEmpty() && candidates.none(SpaceCandidate::canWrite)) {
            throw SyncFailure("read_only_library")
        }
        if (candidates.isNotEmpty()) throw SyncFailure("space_selection_required")
        return createPersonalSpace(serverURL, accessToken)
    }

    fun personalSpaceCandidates(
        serverURL: String,
        accessToken: String,
    ): List<SpaceCandidate> {
        validatedBaseURL(serverURL)
        requireAccessToken(accessToken)
        val spaces = JSONObject(request(serverURL, accessToken, "GET", "v2/spaces"))
            .getJSONArray("spaces")
        return (0 until spaces.length()).map { index ->
            val value = spaces.getJSONObject(index)
            val resolution = spaceResolution(
                value.getJSONObject("scope"),
                value.getString("role"),
            )
            SpaceCandidate(
                spaceID = resolution.spaceID,
                serverInstanceID = resolution.serverInstanceID,
                role = value.getString("role").also {
                    require(it == "owner" || it == "writer" || it == "reader")
                },
            )
        }
    }

    fun createPersonalSpace(serverURL: String, accessToken: String): SpaceResolution =
        JSONObject(request(
            serverURL, accessToken, "POST", "v2/spaces",
            headers = mapOf("Idempotency-Key" to PERSONAL_SPACE_IDEMPOTENCY_KEY),
        )).let { value ->
            spaceResolution(value.getJSONObject("scope"), value.getString("role"))
        }

    fun resolveSpace(
        serverURL: String,
        spaceID: String,
        accessToken: String,
    ): SpaceResolution {
        val value = JSONObject(request(
            serverURL,
            accessToken,
            "GET",
            "v2/spaces/${validatedUUID(spaceID)}",
        ))
        return spaceResolution(value.getJSONObject("scope"), value.getString("role"))
    }

    fun createPairing(
        serverURL: String,
        spaceID: String,
        accessToken: String,
        draft: LibraryKeyBootstrap.PairingDraft,
        expectedServerInstanceID: String,
        expiresInSeconds: Int = LibraryKeyBootstrap.DEFAULT_PAIRING_SECONDS,
    ): PairingRecord {
        require(expiresInSeconds in 60..600)
        val body = JSONObject()
            .put("recipientPublicKey", draft.recipientPublicKey.standardBase64())
            .put("nonce", draft.nonce.standardBase64())
            .put("expiresInSeconds", expiresInSeconds)
            .toString()
        return pairingResponse(spaceID, expectedServerInstanceID, JSONObject(request(
            serverURL,
            accessToken,
            "POST",
            "v2/spaces/${validatedUUID(spaceID)}/pairings",
            body,
        )))
    }

    fun pairing(
        serverURL: String,
        spaceID: String,
        pairingID: String,
        accessToken: String,
        expectedServerInstanceID: String,
    ): PairingRecord = pairingResponse(spaceID, expectedServerInstanceID, JSONObject(request(
        serverURL,
        accessToken,
        "GET",
        "v2/spaces/${validatedUUID(spaceID)}/pairings/${validatedUUID(pairingID)}",
    )))

    fun approvePairing(
        serverURL: String,
        spaceID: String,
        pairingID: String,
        recipientPublicKey: ByteArray,
        ciphertext: ByteArray,
        accessToken: String,
        expectedServerInstanceID: String,
    ): PairingRecord {
        val body = JSONObject()
            .put(
                "recipientKeyHash",
                LibraryKeyBootstrap.recipientKeyHash(recipientPublicKey).standardBase64(),
            )
            .put("algorithm", LibraryKeyBootstrap.PAIRING_ALGORITHM)
            .put("ciphertext", ciphertext.standardBase64())
            .toString()
        return pairingResponse(spaceID, expectedServerInstanceID, JSONObject(request(
            serverURL,
            accessToken,
            "PUT",
            "v2/spaces/${validatedUUID(spaceID)}/pairings/${validatedUUID(pairingID)}/approval",
            body,
        )))
    }

    fun takeApprovedPairing(
        serverURL: String,
        spaceID: String,
        pairingID: String,
        accessToken: String,
        expected: PairingRecord,
        expectedServerInstanceID: String,
    ): PairingRecord {
        val normalizedSpaceID = validatedUUID(spaceID)
        val normalizedPairingID = validatedUUID(pairingID)
        require(expected.spaceID == normalizedSpaceID)
        require(expected.pairingID == normalizedPairingID)
        require(expected.state == "approved")
        require(expected.algorithm == null && expected.ciphertext == null)
        require(expected.expiresAtEpochSeconds >= Instant.now().epochSecond - 30)
        val response = JSONObject(request(
            serverURL, accessToken, "POST",
            "v2/spaces/$normalizedSpaceID/pairings/$normalizedPairingID/claim",
        ))
        validateScopeID(spaceID, response.getJSONObject("scope"), expectedServerInstanceID)
        require(validatedUUID(response.getString("pairingId")) == normalizedPairingID)
        val algorithm = response.getString("algorithm")
        require(algorithm == LibraryKeyBootstrap.PAIRING_ALGORITHM)
        return expected.copy(
            state = "approved",
            algorithm = algorithm,
            ciphertext = response.getString("ciphertext").canonicalStandardBase64(4_096),
        )
    }

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
            "v2/spaces/${validatedUUID(spaceID)}/pairings/${validatedUUID(pairingID)}",
        )
    }

    fun recoveryEnvelope(
        serverURL: String,
        spaceID: String,
        accessToken: String,
        expectedServerInstanceID: String,
    ): RecoveryEnvelopeState {
        val value = JSONObject(request(
            serverURL,
            accessToken,
            "GET",
            "v2/spaces/${validatedUUID(spaceID)}/recovery-envelope",
        ))
        validateScopeID(spaceID, value.getJSONObject("scope"), expectedServerInstanceID)
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
        expectedServerInstanceID: String,
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
            "v2/spaces/${validatedUUID(spaceID)}/recovery-envelope",
            body,
        ))
        validateScopeID(spaceID, value.getJSONObject("scope"), expectedServerInstanceID)
        val envelope = value.getJSONObject("recovery")
        return RecoveryEnvelopeRecord(
            version = envelope.getInt("version"),
            keyEpoch = envelope.getInt("keyEpoch"),
            algorithm = envelope.getString("algorithm"),
            ciphertext = envelope.getString("ciphertext").canonicalStandardBase64(4_096),
        )
    }

    fun hasRemoteRecords(
        serverURL: String,
        spaceID: String,
        accessToken: String,
        expectedServerInstanceID: String,
    ): Boolean {
        val value = JSONObject(request(
            serverURL,
            accessToken,
            "GET",
            "v2/spaces/${validatedUUID(spaceID)}/changes?limit=1",
        ))
        validateScopeID(spaceID, value.getJSONObject("scope"), expectedServerInstanceID)
        return value.getJSONArray("records").length() > 0
    }

    private fun request(
        serverURL: String,
        accessToken: String,
        method: String,
        path: String,
        body: String? = null,
        headers: Map<String, String> = emptyMap(),
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
        headers.forEach(connection::setRequestProperty)
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

    private fun pairingResponse(
        spaceID: String,
        expectedServerInstanceID: String,
        response: JSONObject,
    ): PairingRecord {
        validateScopeID(spaceID, response.getJSONObject("scope"), expectedServerInstanceID)
        return pairingRecord(spaceID, response.getJSONObject("pairing"))
    }

    private fun pairingRecord(spaceID: String, value: JSONObject): PairingRecord {
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
            spaceID = validatedUUID(spaceID),
            recipientPublicKey = publicKey,
            nonce = nonce,
            authenticationTag = tag,
            state = state,
            algorithm = algorithm,
            ciphertext = ciphertext,
            expiresAtEpochSeconds = Instant.parse(value.getString("expiresAt")).epochSecond,
        )
    }

    private fun validateScopeID(
        spaceID: String,
        scope: JSONObject,
        expectedServerInstanceID: String? = null,
    ) {
        val serverInstanceID = validatedUUID(scope.getString("serverInstanceId"))
        if (serverInstanceID == ZERO_UUID ||
            !scope.getString("spaceId").equals(spaceID, ignoreCase = true) ||
            scope.getString("scopeBinding").length !in 32..256) {
            throw SyncFailure("invalid_scope_response")
        }
        if (expectedServerInstanceID != null &&
            !serverInstanceID.equals(validatedUUID(expectedServerInstanceID), ignoreCase = true)) {
            throw SyncFailure("scope_review_required")
        }
        require(validatedUUID(scope.getString("datasetGeneration")) != ZERO_UUID)
        require(validatedUUID(scope.getString("feedEpoch")) != ZERO_UUID)
    }

    private fun spaceResolution(scope: JSONObject, role: String): SpaceResolution {
        val spaceID = scope.getString("spaceId")
        validateScopeID(spaceID, scope)
        require(role == "owner" || role == "writer" || role == "reader")
        return SpaceResolution(
            spaceID = validatedUUID(spaceID),
            serverInstanceID = validatedUUID(scope.getString("serverInstanceId")),
            role = role,
        )
    }

    private fun validateScope(configuration: CloudConfiguration, value: JSONObject) {
        validateScopeID(configuration.spaceID, value)
        fun mismatch(expected: String?, field: String): Boolean =
            expected != null && expected != value.getString(field)
        if (mismatch(configuration.serverInstanceID, "serverInstanceId") ||
            mismatch(configuration.scopeBinding, "scopeBinding") ||
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
        require(configuration.protocolMajor == 2)
        require(configuration.apiBaseURL == configuration.serverURL.trimEnd('/') + "/v2")
        requireAccessToken(accessToken)
        require(UUID_PATTERN.matches(configuration.spaceID))
        if (configuration.requiresServerInstanceReview()) {
            throw SyncFailure("scope_review_required")
        }
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
        const val ZERO_UUID = "00000000-0000-0000-0000-000000000000"
        val UUID_PATTERN = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}")
    }
}

internal fun automaticPersonalSpace(
    candidates: List<HttpSyncClient.SpaceCandidate>,
    existingSpaceID: String?,
): HttpSyncClient.SpaceResolution? {
    val writable = candidates.filter(HttpSyncClient.SpaceCandidate::canWrite)
    existingSpaceID?.let { existing ->
        writable.firstOrNull { it.spaceID.equals(existing, ignoreCase = true) }?.let {
            return HttpSyncClient.SpaceResolution(it.spaceID, it.serverInstanceID, it.role)
        }
    }
    if (writable.size == 1) {
        return writable.single().let {
            HttpSyncClient.SpaceResolution(it.spaceID, it.serverInstanceID, it.role)
        }
    }
    val owned = writable.filter { it.role == "owner" }
    if (owned.size == 1) {
        return owned.single().let {
            HttpSyncClient.SpaceResolution(it.spaceID, it.serverInstanceID, it.role)
        }
    }
    return null
}

class SyncFailure(val code: String) : Exception(code)
