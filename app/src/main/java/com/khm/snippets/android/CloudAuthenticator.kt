package com.khm.snippets.android

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.UUID

internal data class CloudCredentialReplacementCleanupPlan(
    val accessTokensToRetire: List<String>,
    val refreshTokensToRetire: List<String>,
)

/**
 * Native generated-account-key authentication (server ADR 0006). The account key and
 * every credential remain in the device-bound encrypted store and never enter logs,
 * diagnostics, saved-instance state or backups.
 */
class CloudAuthenticator(
    @Suppress("UNUSED_PARAMETER") context: Context,
    private val store: EncryptedStore,
) {
    class CompletedAuthorization(
        val serverURL: String,
        val accessToken: String,
        val accountChange: Boolean,
        val stepUpBinding: CloudStepUpBinding?,
        val resumeBinding: CloudStepUpBinding?,
        /** Set only by account creation, whose response carries the key exactly once. */
        val createdAccountKey: String?,
    ) {
        override fun toString(): String = "CompletedAuthorization(<redacted>)"
    }

    private class StoredSession(
        val serverURL: String,
        val generation: NativeCloudCredentialGeneration,
        val accountID: String,
        /** Null when another device approved this sign-in (ADR 0007): no key was transferred. */
        val accountKey: String?,
        val expiresAtMillis: Long,
    ) {
        override fun toString(): String = "StoredSession(<redacted>)"
    }

    private data class CredentialJournal(
        val serverURL: String,
        val generations: List<NativeCloudCredentialGeneration>,
    )

    /** Creates an account; its grant follows exactly the same journal-first path as sign-in. */
    suspend fun createAccount(
        rawServerURL: String,
        chooseAccount: Boolean = false,
    ): CompletedAuthorization = authorize(rawServerURL, accountKey = null, stepUp = false,
        chooseAccount = chooseAccount, stepUpBinding = null, resumeBinding = null)

    /** [accountKey] must already be canonical; a locally invalid key is never sent. */
    suspend fun signInWithAccountKey(
        rawServerURL: String,
        accountKey: String,
        stepUp: Boolean = false,
        chooseAccount: Boolean = false,
        stepUpBinding: CloudStepUpBinding? = null,
        resumeBinding: CloudStepUpBinding? = null,
    ): CompletedAuthorization {
        cloudAuthGuard(NativeCloudAccountKey.isCanonical(accountKey), "account_key_malformed")
        return authorize(rawServerURL, accountKey, stepUp, chooseAccount, stepUpBinding, resumeBinding)
    }

    private suspend fun authorize(
        rawServerURL: String,
        accountKey: String?,
        stepUp: Boolean,
        chooseAccount: Boolean,
        stepUpBinding: CloudStepUpBinding?,
        resumeBinding: CloudStepUpBinding?,
    ): CompletedAuthorization = withContext(Dispatchers.IO) {
        cloudAuthGuard(!(stepUp && chooseAccount) && stepUp == (stepUpBinding != null) &&
            (stepUpBinding == null || resumeBinding == null) &&
            (accountKey != null || (!stepUp && resumeBinding == null)), "authorization_session_invalid")
        val serverURL = configuredServerURL()
        cloudAuthGuard(nativeCloudServerURL(rawServerURL) == serverURL, "server_identity_mismatch")
        resumeBinding?.let { cloudAuthGuard(it.serverURL == serverURL, "authorization_session_invalid") }
        retireSupersededInteractiveSessions()
        cloudAuthGuard(store.read(AUTH_REVOCATION) == null, "credential_revocation_incomplete")
        loadSession()?.let { cloudAuthGuard(it.serverURL == serverURL, "authorization_state_invalid") }
        val authority = NativeCloudAuthority.parse(serverURL,
            requestJSON("$serverURL/.well-known/snippets-sync"))
        // Once a grant can be issued, finish journaling it even if the caller is cancelled.
        withContext(NonCancellable) {
            val existing = loadSession()
            val grantID = UUID.randomUUID().toString()
            // A rejected profile, key or TTL must not orphan a successfully issued grant.
            val journalIssued: (NativeCloudCredentialGeneration) -> Unit = { issued ->
                writeJournal(AUTH_REPLACEMENT, CredentialJournal(authority.serverURL,
                    listOfNotNull(existing?.generation, issued)))
            }
            val token: NativeCloudTokenResponse
            val storedKey: String
            if (accountKey == null) {
                val created = NativeCloudAccountCreation.parseAfterJournaling(
                    requestJSON(authority.createAccountEndpoint, post = true), grantID, journalIssued)
                token = created.session
                storedKey = created.accountKey
            } else {
                token = NativeCloudTokenResponse.parseAfterJournaling(requestJSON(authority.signInEndpoint,
                    JSONObject().put("accountKey", accountKey)), grantID, persistIssued = journalIssued)
                storedKey = accountKey
            }
            val stored = session(authority.serverURL, token, grantID, storedKey)
            store.write(PENDING_AUTH_SESSION, stored.toJSON())
            CompletedAuthorization(stored.serverURL, stored.generation.accessToken,
                chooseAccount && resumeBinding == null, stepUpBinding, resumeBinding,
                createdAccountKey = storedKey.takeIf { accountKey == null })
        }
    }

    /** ADR 0007 claim result; an approved grant is already journaled and staged as pending. */
    sealed class DeviceClaimOutcome {
        object Pending : DeviceClaimOutcome()

        class Approved(
            val authorization: CompletedAuthorization,
            val spaceID: String,
            val pairingID: String,
        ) : DeviceClaimOutcome()
    }

    /** Whether discovery advertises device-approved sign-in on the pinned origin. */
    suspend fun deviceSignInSupported(rawServerURL: String): Boolean = withContext(Dispatchers.IO) {
        runCatching { deviceSignInAuthority(rawServerURL) }.isSuccess
    }

    /** Opens an unauthenticated device request holding only pairing recipient material. */
    internal suspend fun createDeviceRequest(
        rawServerURL: String,
        recipientPublicKey: ByteArray,
        nonce: ByteArray,
    ): NativeCloudDeviceRequest = withContext(Dispatchers.IO) {
        val authority = deviceSignInAuthority(rawServerURL)
        val encoder = java.util.Base64.getEncoder()
        NativeCloudDeviceRequest.parse(requestJSON(authority.deviceRequestsEndpoint, JSONObject()
            .put("recipientPublicKey", encoder.encodeToString(recipientPublicKey))
            .put("nonce", encoder.encodeToString(nonce))))
    }

    /**
     * Polls a device request once. An approved session takes exactly the account-key path:
     * journal-first replacement grant, then the pending session, which has no account key.
     */
    suspend fun claimDeviceRequest(
        rawServerURL: String,
        requestID: String,
        pollToken: String,
        requestExpiresAtEpochSeconds: Long,
    ): DeviceClaimOutcome = withContext(Dispatchers.IO) {
        val serverURL = configuredServerURL()
        cloudAuthGuard(nativeCloudServerURL(rawServerURL) == serverURL, "server_identity_mismatch")
        cloudAuthGuard(LibraryKeyBootstrap.isDevicePollToken(pollToken), "authorization_state_invalid")
        retireSupersededInteractiveSessions()
        cloudAuthGuard(store.read(AUTH_REVOCATION) == null, "credential_revocation_incomplete")
        loadSession()?.let { cloudAuthGuard(it.serverURL == serverURL, "authorization_state_invalid") }
        val authority = NativeCloudAuthority.forServer(serverURL)
        withContext(NonCancellable) {
            val existing = loadSession()
            val grantID = UUID.randomUUID().toString()
            val response = requestJSON(authority.deviceClaimEndpoint(requestID),
                JSONObject().put("pollToken", pollToken))
            when (val claim = NativeCloudDeviceClaim.parseAfterJournaling(response, grantID,
                requestExpiresAtEpochSeconds) { issued ->
                writeJournal(AUTH_REPLACEMENT, CredentialJournal(serverURL,
                    listOfNotNull(existing?.generation, issued)))
            }) {
                NativeCloudDeviceClaim.Pending -> DeviceClaimOutcome.Pending
                is NativeCloudDeviceClaim.Approved -> {
                    val stored = session(serverURL, claim.session, grantID, accountKey = null)
                    store.write(PENDING_AUTH_SESSION, stored.toJSON())
                    DeviceClaimOutcome.Approved(
                        CompletedAuthorization(stored.serverURL, stored.generation.accessToken,
                            accountChange = false, stepUpBinding = null, resumeBinding = null,
                            createdAccountKey = null),
                        claim.spaceID, claim.pairingID,
                    )
                }
            }
        }
    }

    private fun deviceSignInAuthority(rawServerURL: String): NativeCloudAuthority {
        val serverURL = configuredServerURL()
        cloudAuthGuard(nativeCloudServerURL(rawServerURL) == serverURL, "server_identity_mismatch")
        return NativeCloudAuthority.parseWithDeviceSignIn(serverURL,
            requestJSON("$serverURL/.well-known/snippets-sync"))
    }

    suspend fun freshAccessToken(expectedServerURL: String, forceRefresh: Boolean = false): String =
        freshAccessToken(AUTH_SESSION, expectedServerURL, forceRefresh)

    suspend fun freshPendingAccessToken(expectedServerURL: String, forceRefresh: Boolean = false): String =
        freshAccessToken(PENDING_AUTH_SESSION, expectedServerURL, forceRefresh)

    private suspend fun freshAccessToken(file: String, expectedServerURL: String,
                                         forceRefresh: Boolean): String = withContext(Dispatchers.IO + NonCancellable) {
        retireInterruptedRefresh()
        if (file == AUTH_SESSION) cloudAuthGuard(store.read(AUTH_REPLACEMENT) == null,
            "credential_cleanup_required")
        val stored = loadSession(file) ?: throw CloudAuthFailure("sign_in_required")
        cloudAuthGuard(stored.serverURL == nativeCloudServerURL(expectedServerURL) &&
            stored.serverURL == configuredServerURL(), "sign_in_required")
        if (!forceRefresh && stored.expiresAtMillis - System.currentTimeMillis() > 60_000) {
            return@withContext stored.generation.accessToken
        }
        if (file == PENDING_AUTH_SESSION) {
            val journal = loadJournal(AUTH_REPLACEMENT, stored.serverURL)
                ?: throw CloudAuthFailure("authorization_state_invalid")
            cloudAuthGuard(journal.generations.size < 16, "authorization_state_invalid")
        }
        val response = requestJSON(NativeCloudAuthority.forServer(stored.serverURL).refreshEndpoint,
            JSONObject().put("refreshToken", stored.generation.refreshToken))
        val token = try {
            NativeCloudTokenResponse.parseAfterJournaling(response, stored.generation.grantID,
                stored.generation.refreshToken, stored.accountID) { issued ->
                store.write(AUTH_REFRESH, JSONObject().put("schemaVersion", 1)
                    .put("serverURL", stored.serverURL).put("sessionFile", file)
                    .put("previous", generationJSON(stored.generation))
                    .put("issued", generationJSON(issued)).toString())
            }
        } catch (_: Exception) {
            try { retireInterruptedRefresh() }
            catch (_: Exception) { throw CloudAuthFailure("credential_cleanup_required") }
            throw CloudAuthFailure("sign_in_required")
        }
        val updated = session(stored.serverURL, token, stored.generation.grantID, stored.accountKey)
        val journalFile = if (file == PENDING_AUTH_SESSION) AUTH_REPLACEMENT else AUTH_REVOCATION
        loadJournal(journalFile, stored.serverURL)?.let {
            writeJournal(journalFile, it.copy(generations =
                (it.generations + listOf(stored.generation, updated.generation)).distinct()))
        }
        store.write(file, updated.toJSON())
        retireInterruptedRefresh()
        updated.generation.accessToken
    }

    fun hasSession(serverURL: String? = null): Boolean = runCatching {
        store.read(AUTH_REPLACEMENT) == null && store.read(AUTH_REFRESH) == null &&
            hasSessionFile(AUTH_SESSION, serverURL)
    }.getOrDefault(false)

    fun hasPendingAuthorization(serverURL: String? = null): Boolean = runCatching {
        hasSessionFile(PENDING_AUTH_SESSION, serverURL)
    }.getOrDefault(false)

    private fun hasSessionFile(file: String, serverURL: String?): Boolean {
        val session = loadSession(file) ?: return false
        return session.serverURL == configuredServerURL() &&
            (serverURL == null || session.serverURL == nativeCloudServerURL(serverURL))
    }

    fun commitPendingAuthorization(expectedServerURL: String) {
        retireInterruptedRefresh()
        val candidate = loadSession(PENDING_AUTH_SESSION)
            ?: throw CloudAuthFailure("authorization_state_invalid")
        cloudAuthGuard(candidate.serverURL == nativeCloudServerURL(expectedServerURL) &&
            candidate.serverURL == configuredServerURL(), "authorization_state_invalid")
        val journal = loadJournal(AUTH_REPLACEMENT, candidate.serverURL)
            ?: throw CloudAuthFailure("authorization_state_invalid")
        cloudAuthGuard(candidate.generation in journal.generations, "authorization_state_invalid")
        store.write(AUTH_SESSION, candidate.toJSON())
    }

    suspend fun finalizePendingAuthorization() { retireSupersededInteractiveSessions() }

    suspend fun discardPendingAuthorization() {
        val candidate = loadSession(PENDING_AUTH_SESSION)
        if (store.read(AUTH_REPLACEMENT) == null && candidate != null) {
            writeJournal(AUTH_REPLACEMENT, CredentialJournal(candidate.serverURL, listOf(candidate.generation)))
        }
        retireSupersededInteractiveSessions()
    }

    fun hasPendingRevocation(): Boolean =
        runCatching { store.read(AUTH_REVOCATION) != null }.getOrDefault(true)

    fun hasPendingCredentialCleanup(): Boolean =
        runCatching { store.read(AUTH_REPLACEMENT) != null || store.read(AUTH_REFRESH) != null }.getOrDefault(true)

    suspend fun revokeCurrentSession() = withContext(Dispatchers.IO) {
        retireSupersededInteractiveSessions()
        val current = loadSession()
        val journal = loadJournal(AUTH_REVOCATION, current?.serverURL)
            ?: current?.let { CredentialJournal(it.serverURL, listOf(it.generation)) }
                ?.also { writeJournal(AUTH_REVOCATION, it) }
            ?: return@withContext
        retire(journal.serverURL, journal.generations.map { it.accessToken }.distinct(),
            journal.generations.map { it.refreshToken }.distinct())
        // Keep the journal until the repository commits the local erase.
    }

    fun forgetLocalSession() {
        listOf(AUTH_SESSION, PENDING_AUTH_SESSION, AUTH_REVOCATION, AUTH_REPLACEMENT, AUTH_REFRESH).forEach(store::delete)
    }

    /** Display form of the committed account's ID, or null when no session is usable. */
    fun accountIDDisplay(): String? = runCatching {
        loadSession()?.accountID?.let(::nativeCloudAccountIDDisplay)
    }.getOrNull()

    /**
     * The committed session's canonical account key, or null on a device that another
     * device signed in. Callers disclose it only after device-owner authentication and
     * never retain it beyond one presentation.
     */
    fun currentAccountKey(expectedServerURL: String): String? {
        val stored = loadSession() ?: throw CloudAuthFailure("sign_in_required")
        cloudAuthGuard(stored.serverURL == nativeCloudServerURL(expectedServerURL), "sign_in_required")
        return stored.accountKey
    }

    /** Whether the committed session holds an account key that can be shown. */
    fun hasAccountKey(): Boolean = runCatching { loadSession()?.accountKey != null }.getOrDefault(false)

    /** Whether a newly created key still belongs to the committed (or pending) session. */
    fun retainsAccountKey(accountKey: String, includePending: Boolean): Boolean = runCatching {
        loadSession()?.accountKey == accountKey ||
            (includePending && loadSession(PENDING_AUTH_SESSION)?.accountKey == accountKey)
    }.getOrDefault(false)

    private fun session(serverURL: String, token: NativeCloudTokenResponse, grantID: String,
                        accountKey: String?) =
        StoredSession(serverURL, NativeCloudCredentialGeneration(grantID, token.accessToken,
            token.refreshToken), token.accountID, accountKey,
            System.currentTimeMillis() + token.expiresIn * 1_000L)

    private fun StoredSession.toJSON(): String = JSONObject()
        .put("schemaVersion", SESSION_SCHEMA_VERSION).put("serverURL", serverURL)
        .put("accountID", accountID).put("accountKey", accountKey ?: JSONObject.NULL)
        .put("expiresAtMillis", expiresAtMillis)
        .put("generation", generationJSON(generation)).toString()

    private fun loadSession(file: String = AUTH_SESSION): StoredSession? {
        val raw = store.read(file) ?: return null
        try {
            cloudAuthGuard(raw.toByteArray().size <= SESSION_MAX_BYTES, "authorization_state_invalid")
            val value = JSONObject(raw)
            val schemaVersion = value.optInt("schemaVersion")
            // Schema 1 held a removed email-code session without an account key. It can
            // never be used again, so it reads as signed out and the user signs in again.
            if (schemaVersion in 1 until SESSION_SCHEMA_VERSION) return null
            cloudAuthGuard(schemaVersion == SESSION_SCHEMA_VERSION, "authorization_state_invalid")
            val serverURL = nativeCloudServerURL(value.getString("serverURL"))
            cloudAuthGuard(serverURL == configuredServerURL(), "authorization_state_invalid")
            val generation = parseGeneration(value.getJSONObject("generation"))
            val accountID = value.getString("accountID")
            cloudAuthGuard(value.has("accountKey"), "authorization_state_invalid")
            val accountKey = if (value.isNull("accountKey")) null else value.getString("accountKey")
            val expiresAt = value.getLong("expiresAtMillis")
            cloudAuthGuard(nativeCloudAccountID(accountID) == accountID &&
                (accountKey == null || NativeCloudAccountKey.isCanonical(accountKey)) && expiresAt > 0 &&
                expiresAt <= System.currentTimeMillis() + 300_000L, "authorization_state_invalid")
            return StoredSession(serverURL, generation, accountID, accountKey, expiresAt)
        } catch (error: CloudAuthFailure) { throw error }
        catch (_: Exception) { throw CloudAuthFailure("authorization_state_invalid") }
    }

    private fun generationJSON(value: NativeCloudCredentialGeneration) = JSONObject()
        .put("grantID", value.grantID).put("accessToken", value.accessToken)
        .put("refreshToken", value.refreshToken)

    private fun parseGeneration(value: JSONObject): NativeCloudCredentialGeneration {
        val id = value.getString("grantID")
        cloudAuthGuard(UUID.fromString(id).toString() == id, "authorization_state_invalid")
        val access = value.getString("accessToken")
        val refresh = value.getString("refreshToken")
        validateNativeCloudToken(access); validateNativeCloudToken(refresh)
        return NativeCloudCredentialGeneration(id, access, refresh)
    }

    private fun writeJournal(file: String, journal: CredentialJournal) {
        cloudAuthGuard(journal.generations.size in 1..16, "authorization_state_invalid")
        val raw = JSONObject().put("schemaVersion", 1).put("serverURL", journal.serverURL)
            .put("generations", JSONArray(journal.generations.map(::generationJSON))).toString()
        cloudAuthGuard(raw.toByteArray().size <= JOURNAL_MAX_BYTES, "authorization_state_invalid")
        store.write(file, raw)
    }

    private fun loadJournal(file: String, expectedServerURL: String? = null): CredentialJournal? {
        val raw = store.read(file) ?: return null
        try {
            cloudAuthGuard(raw.toByteArray().size <= JOURNAL_MAX_BYTES, "authorization_state_invalid")
            val value = JSONObject(raw)
            cloudAuthGuard(value.keys().asSequence().toSet() == setOf("schemaVersion", "serverURL", "generations") &&
                value.getInt("schemaVersion") == 1, "authorization_state_invalid")
            val serverURL = nativeCloudServerURL(value.getString("serverURL"))
            cloudAuthGuard(serverURL == configuredServerURL() &&
                (expectedServerURL == null || serverURL == expectedServerURL), "authorization_state_invalid")
            val entries = value.getJSONArray("generations")
            cloudAuthGuard(entries.length() in 1..16, "authorization_state_invalid")
            val generations = (0 until entries.length()).map { parseGeneration(entries.getJSONObject(it)) }
            cloudAuthGuard(generations.distinct().size == generations.size, "authorization_state_invalid")
            return CredentialJournal(serverURL, generations)
        } catch (error: CloudAuthFailure) { throw error }
        catch (_: Exception) { throw CloudAuthFailure("authorization_state_invalid") }
    }

    private suspend fun retireSupersededInteractiveSessions() = withContext(Dispatchers.IO) {
        retireInterruptedRefresh()
        val current = loadSession()
        val pending = loadSession(PENDING_AUTH_SESSION)
        val journal = loadJournal(AUTH_REPLACEMENT, (current ?: pending)?.serverURL)
            ?: return@withContext
        val plan = nativeCloudReplacementCleanupPlan(current?.generation, journal.generations)
            ?: throw CloudAuthFailure("authorization_state_invalid")
        retire(journal.serverURL, plan.accessTokensToRetire, plan.refreshTokensToRetire)
        store.delete(PENDING_AUTH_SESSION)
        store.delete(AUTH_REPLACEMENT)
    }

    /** Rejected or uncommitted refresh metadata retires the issued family before local erase. */
    private fun retireInterruptedRefresh() {
        val raw = store.read(AUTH_REFRESH) ?: return
        val serverURL: String
        val file: String
        val plan: NativeCloudRefreshCleanupPlan
        try {
            cloudAuthGuard(raw.toByteArray().size <= SESSION_MAX_BYTES, "authorization_state_invalid")
            val value = JSONObject(raw)
            cloudAuthGuard(value.keys().asSequence().toSet() ==
                setOf("schemaVersion", "serverURL", "sessionFile", "previous", "issued") &&
                value.getInt("schemaVersion") == 1, "authorization_state_invalid")
            serverURL = nativeCloudServerURL(value.getString("serverURL"))
            cloudAuthGuard(serverURL == configuredServerURL(), "authorization_state_invalid")
            file = value.getString("sessionFile")
            cloudAuthGuard(file == AUTH_SESSION || file == PENDING_AUTH_SESSION, "authorization_state_invalid")
            plan = nativeCloudRefreshCleanupPlan(loadSession(file)?.generation,
                parseGeneration(value.getJSONObject("previous")), parseGeneration(value.getJSONObject("issued")))
                ?: throw CloudAuthFailure("authorization_state_invalid")
        } catch (error: CloudAuthFailure) { throw error }
        catch (_: Exception) { throw CloudAuthFailure("authorization_state_invalid") }
        retire(serverURL, plan.accessTokensToRetire, plan.refreshTokensToRetire)
        if (plan.discardStoredSession) store.delete(file)
        // Deletion order permits retry after a crash without ever trusting rejected metadata.
        store.delete(AUTH_REFRESH)
    }

    private fun retire(serverURL: String, accessTokens: List<String>, refreshTokens: List<String>) {
        val endpoint = NativeCloudAuthority.forServer(serverURL).revokeEndpoint
        accessTokens.forEach { requestJSON(endpoint,
            JSONObject().put("token", it).put("tokenTypeHint", "access_token"), emptyResponse = true) }
        refreshTokens.forEach { requestJSON(endpoint,
            JSONObject().put("token", it).put("tokenTypeHint", "refresh_token"), emptyResponse = true) }
    }

    /**
     * HTTPS origin is pinned before any credential is sent, and redirects are never followed.
     * A [post] without [body] sends an empty body with `Content-Length: 0`.
     */
    private fun requestJSON(endpoint: String, body: JSONObject? = null,
                            emptyResponse: Boolean = false, post: Boolean = body != null): JSONObject {
        val uri = URI(endpoint)
        val origin = URI(configuredServerURL())
        cloudAuthGuard(uri.scheme == origin.scheme && uri.host == origin.host && uri.port == origin.port &&
            uri.userInfo == null && uri.fragment == null && uri.query == null, "server_identity_mismatch")
        val connection = uri.toURL().openConnection() as HttpURLConnection
        try {
            connection.requestMethod = if (post) "POST" else "GET"
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("Accept", "application/json")
            if (post) {
                val bytes = body?.toString()?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
                connection.doOutput = true
                if (body != null) connection.setRequestProperty("Content-Type", "application/json")
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { it.write(bytes) }
            }
            val status = connection.responseCode
            val bytes = readBounded(if (status in 200..299) connection.inputStream else connection.errorStream)
            if (status != if (emptyResponse) 204 else 200) {
                val allowed = setOf("invalid_account_key", "rate_limited", "authentication_required",
                    "dependency_unavailable", "not_found", "pairing_expired", "conflict")
                val error = runCatching { JSONObject(bytes.toString(Charsets.UTF_8)) }.getOrNull()
                val code = (error?.optJSONObject("problem")?.optString("code") ?: error?.optString("code"))
                    ?.takeIf { it in allowed } ?: "server_request_failed"
                val retry = nativeCloudRetryAfter(connection.getHeaderField("Retry-After"))
                throw CloudAuthFailure(code, retry)
            }
            if (emptyResponse) {
                cloudAuthGuard(bytes.isEmpty(), "server_response_invalid")
                return JSONObject()
            }
            return try { JSONObject(bytes.toString(Charsets.UTF_8)) }
                catch (_: Exception) { throw CloudAuthFailure("server_response_invalid") }
        } catch (error: CloudAuthFailure) { throw error }
        catch (_: java.io.IOException) { throw CloudAuthFailure("server_unavailable") }
        finally { connection.disconnect() }
    }

    private fun readBounded(input: java.io.InputStream?): ByteArray {
        if (input == null) return ByteArray(0)
        input.use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8_192)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                cloudAuthGuard(output.size() <= RESPONSE_MAX_BYTES - count, "server_response_invalid")
                output.write(buffer, 0, count)
            }
            return output.toByteArray()
        }
    }

    private fun configuredServerURL(): String {
        cloudAuthGuard(BuildConfig.SNIPPETS_CLOUD_URL.isNotBlank(), "cloud_build_not_configured")
        return nativeCloudServerURL(BuildConfig.SNIPPETS_CLOUD_URL)
    }

    private companion object {
        const val RESPONSE_MAX_BYTES = 256 * 1024
        const val SESSION_MAX_BYTES = 128 * 1024
        const val JOURNAL_MAX_BYTES = 1024 * 1024
        /** Schema 2 binds the canonical account key (or null after ADR 0007 approval). */
        const val SESSION_SCHEMA_VERSION = 2
        // Old browser sessions remain unconsumed. Native authentication never guesses
        // an account from a legacy identity claim, JWT or saved library configuration.
        const val AUTH_SESSION = "native-cloud-session.enc"
        const val PENDING_AUTH_SESSION = "native-cloud-pending-session.enc"
        const val AUTH_REPLACEMENT = "native-cloud-replacement-journal.enc"
        const val AUTH_REVOCATION = "native-cloud-revocation-journal.enc"
        const val AUTH_REFRESH = "native-cloud-refresh-journal.enc"
    }
}

class CloudAuthFailure(val code: String, val retryAfterSeconds: Int? = null) : Exception(code)
