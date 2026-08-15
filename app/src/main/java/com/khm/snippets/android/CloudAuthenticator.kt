package com.khm.snippets.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import net.openid.appauth.AuthorizationException
import net.openid.appauth.AuthorizationRequest
import net.openid.appauth.AuthorizationResponse
import net.openid.appauth.AuthorizationService
import net.openid.appauth.AuthorizationServiceConfiguration
import net.openid.appauth.AuthorizationServiceDiscovery
import net.openid.appauth.GrantTypeValues
import net.openid.appauth.ResponseTypeValues
import net.openid.appauth.TokenRequest
import net.openid.appauth.TokenResponse
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal data class CloudCredentialRevocationPlan(
    val accessTokens: List<String>,
    val refreshTokens: List<String>,
)

/** The durable journal wins if refresh crashed before replacing the primary session. */
internal fun cloudCredentialRevocationPlan(
    sessionAccessToken: String?,
    sessionRefreshToken: String?,
    journalAccessTokens: List<String>,
    journalRefreshTokens: List<String>,
): CloudCredentialRevocationPlan = CloudCredentialRevocationPlan(
    accessTokens = (journalAccessTokens + listOfNotNull(sessionAccessToken)).distinct(),
    refreshTokens = (journalRefreshTokens + listOfNotNull(sessionRefreshToken)).distinct(),
)

/**
 * Browser-based OIDC for the native app. Passkeys, Apple and Google stay in the
 * system browser; Snippets has no password and does not require or consume email.
 * It persists only a minimal token session inside the device-bound encrypted store.
 * ID tokens and their profile claims are deliberately discarded.
 */
class CloudAuthenticator(
    context: Context,
    private val store: EncryptedStore,
) {
    data class CompletedAuthorization(
        val serverURL: String,
        val accessToken: String,
    )

    private data class ServiceDiscovery(
        val serverURL: String,
        val issuer: String,
        val resource: String,
        val clientID: String,
        val scopes: List<String>,
        val maximumAccessTokenAgeSeconds: Int,
        val stepUpMaximumAgeSeconds: Int,
        val stepUpACRValues: List<String>,
    )

    private data class StoredSession(
        val serverURL: String,
        val issuer: String,
        val resource: String,
        val authorizationEndpoint: String,
        val tokenEndpoint: String,
        val revocationEndpoint: String,
        val clientID: String,
        val maximumAccessTokenAgeSeconds: Int,
        val accessToken: String,
        val refreshToken: String,
        val expiresAtMillis: Long,
    )

    private data class RevocationJournal(
        val serverURL: String,
        val issuer: String,
        val resource: String,
        val revocationEndpoint: String,
        val clientID: String,
        val accessTokens: List<String>,
        val refreshTokens: List<String>,
    )

    private val applicationContext = context.applicationContext

    suspend fun authorizationIntent(
        rawServerURL: String,
        stepUp: Boolean = false,
    ): Intent = withContext(Dispatchers.IO) {
        guard(store.read(AUTH_REVOCATION) == null, "credential_revocation_incomplete")
        val pinnedServerURL = configuredServerURL()
        guard(normalizedBaseURL(rawServerURL) == pinnedServerURL, "server_identity_mismatch")
        val redirectURI = configuredRedirectURI()
        val discovery = fetchServiceDiscovery(pinnedServerURL)
        val oidcConfiguration = fetchOIDCConfiguration(discovery.issuer)
        validateOIDCConfiguration(oidcConfiguration)

        val builder = AuthorizationRequest.Builder(
            oidcConfiguration,
            discovery.clientID,
            ResponseTypeValues.CODE,
            redirectURI,
        ).setScopes(discovery.scopes)
        val parameters = mutableMapOf("resource" to discovery.resource)
        if (stepUp) {
            builder.setPrompt("login")
            parameters["max_age"] = "0"
            if (discovery.stepUpACRValues.isNotEmpty()) {
                parameters["acr_values"] = discovery.stepUpACRValues.joinToString(" ")
            }
        }
        builder.setAdditionalParameters(parameters)
        val request = builder.build()
        guard(!request.state.isNullOrBlank(), "authorization_session_invalid")
        guard(!request.nonce.isNullOrBlank(), "authorization_session_invalid")
        guard(
            request.codeVerifierChallengeMethod == AuthorizationRequest.CODE_CHALLENGE_METHOD_S256 &&
                !request.codeVerifier.isNullOrBlank(),
            "authorization_session_invalid",
        )
        store.write(PENDING, JSONObject()
            .put("schemaVersion", 2)
            .put("serverURL", discovery.serverURL)
            .put("issuer", discovery.issuer)
            .put("resource", discovery.resource)
            .put("clientID", discovery.clientID)
            .put("redirectURI", redirectURI.toString())
            .put("maximumAccessTokenAgeSeconds", discovery.maximumAccessTokenAgeSeconds)
            .put("state", request.state)
            .toString())

        val service = AuthorizationService(applicationContext)
        try {
            service.getAuthorizationRequestIntent(request)
        } finally {
            service.dispose()
        }
    }

    suspend fun completeAuthorization(intent: Intent?): CompletedAuthorization =
        withContext(Dispatchers.IO) {
            val pending = store.read(PENDING)?.let(::JSONObject)
                ?: throw CloudAuthFailure("authorization_session_missing")
            try {
                guard(pending.optInt("schemaVersion") == 2, "authorization_session_missing")
                val exception = intent?.let(AuthorizationException::fromIntent)
                val response = intent?.let(AuthorizationResponse::fromIntent)
                if (exception != null || response == null) {
                    throw CloudAuthFailure("authorization_cancelled")
                }
                val clientID = pending.getString("clientID")
                val resource = pending.getString("resource")
                val redirectURI = configuredRedirectURI()
                guard(response.request.clientId == clientID, "authorization_response_mismatch")
                guard(response.request.redirectUri == redirectURI, "authorization_response_mismatch")
                guard(pending.getString("redirectURI") == redirectURI.toString(), "authorization_response_mismatch")
                guard(
                    response.request.additionalParameters["resource"] == resource,
                    "authorization_response_mismatch",
                )
                guard(response.state == pending.getString("state"), "authorization_response_mismatch")
                guard(response.request.responseType == ResponseTypeValues.CODE, "authorization_response_mismatch")
                guard(
                    response.request.codeVerifierChallengeMethod ==
                        AuthorizationRequest.CODE_CHALLENGE_METHOD_S256 &&
                        !response.request.codeVerifier.isNullOrBlank(),
                    "authorization_response_mismatch",
                )
                guard(
                    response.request.configuration.discoveryDoc?.issuer == pending.getString("issuer"),
                    "authorization_response_mismatch",
                )

                val tokenResponse = performTokenRequest(
                    response.createTokenExchangeRequest(mapOf("resource" to resource)),
                )
                val stored = sessionFromTokenResponse(
                    serverURL = pending.getString("serverURL"),
                    issuer = pending.getString("issuer"),
                    resource = resource,
                    configuration = response.request.configuration,
                    clientID = clientID,
                    maximumAccessTokenAgeSeconds = pending.getInt("maximumAccessTokenAgeSeconds"),
                    response = tokenResponse,
                )
                store.write(AUTH_SESSION, stored.toJSON())
                store.delete(LEGACY_AUTH_STATE)
                store.delete(LEGACY_AUTH_SERVER)
                CompletedAuthorization(
                    serverURL = stored.serverURL,
                    accessToken = stored.accessToken,
                )
            } finally {
                store.delete(PENDING)
            }
        }

    suspend fun freshAccessToken(
        expectedServerURL: String,
        forceRefresh: Boolean = false,
    ): String = withContext(Dispatchers.IO) {
        val stored = loadSession() ?: throw CloudAuthFailure("sign_in_required")
        val pinnedServerURL = configuredServerURL()
        guard(
            stored.serverURL == pinnedServerURL &&
                normalizedBaseURL(expectedServerURL) == pinnedServerURL,
            "sign_in_required",
        )
        if (!forceRefresh &&
            stored.expiresAtMillis - System.currentTimeMillis() > REFRESH_EARLY_MILLIS) {
            return@withContext stored.accessToken
        }

        val configuration = AuthorizationServiceConfiguration(
            Uri.parse(stored.authorizationEndpoint),
            Uri.parse(stored.tokenEndpoint),
        )
        val request = TokenRequest.Builder(configuration, stored.clientID)
            .setGrantType(GrantTypeValues.REFRESH_TOKEN)
            .setRefreshToken(stored.refreshToken)
            .setAdditionalParameters(mapOf("resource" to stored.resource))
            .build()
        val response = try {
            performTokenRequest(request)
        } catch (_: CloudAuthFailure) {
            throw CloudAuthFailure("sign_in_required")
        }
        val updated = sessionFromTokenResponse(
            serverURL = stored.serverURL,
            issuer = stored.issuer,
            resource = stored.resource,
            configuration = configuration,
            clientID = stored.clientID,
            maximumAccessTokenAgeSeconds = stored.maximumAccessTokenAgeSeconds,
            response = response,
            previousRefreshToken = stored.refreshToken,
            previousRevocationEndpoint = stored.revocationEndpoint,
        )
        // If logout forced this refresh, journal both generations before replacing
        // the stored session. Process death cannot otherwise strand the old refresh
        // token at a provider that does not invalidate it during rotation.
        extendRevocationJournalIfPresent(listOf(stored, updated))
        store.write(AUTH_SESSION, updated.toJSON())
        updated.accessToken
    }

    fun hasSession(serverURL: String? = null): Boolean {
        return try {
            val stored = loadSession() ?: return false
            val pinnedServerURL = configuredServerURL()
            stored.serverURL == pinnedServerURL &&
                (serverURL == null || normalizedBaseURL(serverURL) == pinnedServerURL)
        } catch (_: Exception) {
            false
        }
    }

    fun hasPendingRevocation(): Boolean =
        runCatching { store.read(AUTH_REVOCATION) != null }.getOrDefault(true)

    suspend fun revokeCurrentSession() = withContext(Dispatchers.IO) {
        val initialSession = loadSession()
        if (initialSession == null) {
            guard(store.read(AUTH_REVOCATION) == null, "authorization_state_invalid")
        } else {
            val session = initialSession
            val journal = loadRevocationJournal(session)
                ?: makeRevocationJournal(listOf(session)).also(::storeRevocationJournal)
            val plan = cloudCredentialRevocationPlan(
                sessionAccessToken = session.accessToken,
                sessionRefreshToken = session.refreshToken,
                journalAccessTokens = journal.accessTokens,
                journalRefreshTokens = journal.refreshTokens,
            )
            // A 401 for the old primary session must not trigger refresh: after a
            // crash the usable rotated access token may exist only in the journal.
            // Iterate every generation; provider revocation then closes every
            // refresh token that could mint another one.
            plan.accessTokens.forEach { token ->
                val resourceStatus = revokeResourceAccessToken(session.serverURL, token)
                guard(
                    resourceStatus == 204 || resourceStatus == 401,
                    "credential_revocation_failed",
                )
            }
            revokeProviderCredentials(session, plan)
            // The journal remains until the repository durably commits local erase.
            // A crash in that handoff repeats both idempotent revocation protocols.
        }
    }

    fun forgetLocalSession() {
        store.delete(PENDING)
        store.delete(AUTH_SESSION)
        store.delete(LEGACY_AUTH_STATE)
        store.delete(LEGACY_AUTH_SERVER)
        store.delete(AUTH_REVOCATION)
    }

    private suspend fun performTokenRequest(request: TokenRequest): TokenResponse {
        val service = AuthorizationService(applicationContext)
        try {
            return suspendCancellableCoroutine { continuation ->
                service.performTokenRequest(request) { tokenResponse, exception ->
                    if (!continuation.isActive) return@performTokenRequest
                    if (exception != null || tokenResponse == null) {
                        continuation.resumeWithException(CloudAuthFailure("token_exchange_failed"))
                    } else {
                        continuation.resume(tokenResponse)
                    }
                }
            }
        } finally {
            service.dispose()
        }
    }

    private fun sessionFromTokenResponse(
        serverURL: String,
        issuer: String,
        resource: String,
        configuration: AuthorizationServiceConfiguration,
        clientID: String,
        maximumAccessTokenAgeSeconds: Int,
        response: TokenResponse,
        previousRefreshToken: String? = null,
        previousRevocationEndpoint: String? = null,
    ): StoredSession {
        guard(response.tokenType?.equals("Bearer", ignoreCase = true) == true, "token_exchange_failed")
        val accessToken = response.accessToken ?: throw CloudAuthFailure("access_token_missing")
        val refreshToken = response.refreshToken ?: previousRefreshToken
            ?: throw CloudAuthFailure("refresh_token_missing")
        validateToken(accessToken, "access_token_missing")
        validateToken(refreshToken, "refresh_token_missing")
        validateResourceAudience(accessToken, resource)
        val now = System.currentTimeMillis()
        val expiresAt = response.accessTokenExpirationTime
            ?: throw CloudAuthFailure("token_exchange_failed")
        guard(
            expiresAt >= now + MIN_TOKEN_LIFETIME_MILLIS &&
                expiresAt <= now + MAX_TOKEN_LIFETIME_MILLIS,
            "token_exchange_failed",
        )
        return StoredSession(
            serverURL = normalizedBaseURL(serverURL),
            issuer = normalizedIssuer(issuer),
            resource = normalizedBaseURL(resource),
            authorizationEndpoint = secureEndpoint(configuration.authorizationEndpoint.toString()),
            tokenEndpoint = secureEndpoint(configuration.tokenEndpoint.toString()),
            revocationEndpoint = previousRevocationEndpoint ?: secureEndpoint(
                configuration.discoveryDoc?.docJson?.getString("revocation_endpoint")
                    ?: throw CloudAuthFailure("identity_provider_configuration_invalid"),
            ),
            clientID = clientID.also {
                guard(it.isNotBlank() && it.toByteArray().size <= 256, "token_exchange_failed")
            },
            maximumAccessTokenAgeSeconds = maximumAccessTokenAgeSeconds.also {
                guard(it in 60..86_400, "token_exchange_failed")
            },
            accessToken = accessToken,
            refreshToken = refreshToken,
            expiresAtMillis = minOf(
                expiresAt,
                now + maximumAccessTokenAgeSeconds * 1_000L,
            ),
        )
    }

    private fun StoredSession.toJSON(): String = JSONObject()
        .put("schemaVersion", 4)
        .put("serverURL", serverURL)
        .put("issuer", issuer)
        .put("resource", resource)
        .put("authorizationEndpoint", authorizationEndpoint)
        .put("tokenEndpoint", tokenEndpoint)
        .put("revocationEndpoint", revocationEndpoint)
        .put("clientID", clientID)
        .put("maximumAccessTokenAgeSeconds", maximumAccessTokenAgeSeconds)
        .put("accessToken", accessToken)
        .put("refreshToken", refreshToken)
        .put("expiresAtMillis", expiresAtMillis)
        .toString()
        .also { guard(it.toByteArray().size <= SESSION_MAX_BYTES, "authorization_state_invalid") }

    private fun loadSession(): StoredSession? {
        val raw = store.read(AUTH_SESSION) ?: return null
        try {
            guard(raw.toByteArray().size <= SESSION_MAX_BYTES, "authorization_state_invalid")
            val value = JSONObject(raw)
            guard(value.optInt("schemaVersion") == 4, "authorization_state_invalid")
            val clientID = value.getString("clientID")
            guard(
                clientID.isNotBlank() && clientID.toByteArray().size <= 256,
                "authorization_state_invalid",
            )
            val accessToken = value.getString("accessToken")
            val refreshToken = value.getString("refreshToken")
            val maximumAccessTokenAgeSeconds = value.getInt("maximumAccessTokenAgeSeconds")
            guard(
                maximumAccessTokenAgeSeconds in 60..86_400,
                "authorization_state_invalid",
            )
            validateToken(accessToken, "authorization_state_invalid")
            validateToken(refreshToken, "authorization_state_invalid")
            val expiresAt = value.getLong("expiresAtMillis")
            val now = System.currentTimeMillis()
            guard(
                expiresAt > 0 && expiresAt <= now + MAX_TOKEN_LIFETIME_MILLIS,
                "authorization_state_invalid",
            )
            val serverURL = normalizedBaseURL(value.getString("serverURL"))
            val resource = normalizedBaseURL(value.getString("resource"))
            guard(resource == serverURL, "authorization_state_invalid")
            return StoredSession(
                serverURL = serverURL,
                issuer = normalizedIssuer(value.getString("issuer")),
                resource = resource,
                authorizationEndpoint = secureEndpoint(value.getString("authorizationEndpoint")),
                tokenEndpoint = secureEndpoint(value.getString("tokenEndpoint")),
                revocationEndpoint = secureEndpoint(value.getString("revocationEndpoint")),
                clientID = clientID,
                maximumAccessTokenAgeSeconds = maximumAccessTokenAgeSeconds,
                accessToken = accessToken,
                refreshToken = refreshToken,
                expiresAtMillis = expiresAt,
            )
        } catch (failure: CloudAuthFailure) {
            throw failure
        } catch (_: Exception) {
            throw CloudAuthFailure("authorization_state_invalid")
        }
    }

    private fun fetchOIDCConfiguration(issuer: String): AuthorizationServiceConfiguration {
        try {
            val discoveryURL = URI(issuer.trimEnd('/') + "/.well-known/openid-configuration")
                .toURL()
            val connection = discoveryURL.openConnection() as HttpURLConnection
            connection.requestMethod = "GET"
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("Accept", "application/json")
            val status = connection.responseCode
            val data = readBounded(
                if (status == 200) connection.inputStream else connection.errorStream,
                DISCOVERY_MAX_BYTES,
            )
            guard(status == 200, "identity_provider_unavailable")
            val document = JSONObject(data.toString(Charsets.UTF_8))
            guard(document.getString("issuer") == issuer, "identity_provider_configuration_invalid")
            return AuthorizationServiceConfiguration(AuthorizationServiceDiscovery(document))
        } catch (failure: CloudAuthFailure) {
            throw failure
        } catch (_: Exception) {
            throw CloudAuthFailure("identity_provider_unavailable")
        }
    }

    private fun fetchServiceDiscovery(rawServerURL: String): ServiceDiscovery {
        val serverURL = normalizedBaseURL(rawServerURL)
        val connection = URI("$serverURL/")
            .resolve(".well-known/snippets-sync")
            .toURL()
            .openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.connectTimeout = 15_000
        connection.readTimeout = 15_000
        connection.instanceFollowRedirects = false
        connection.setRequestProperty("Accept", "application/json")
        val status = connection.responseCode
        val data = readBounded(
            if (status in 200..299) connection.inputStream else connection.errorStream,
            DISCOVERY_MAX_BYTES,
        )
        if (status != 200) throw CloudAuthFailure("server_discovery_failed")
        val value = try {
            JSONObject(data.toString(Charsets.UTF_8))
        } catch (_: Exception) {
            throw CloudAuthFailure("server_discovery_invalid")
        }
        guard(value.optInt("protocolMajor") == 1, "server_protocol_incompatible")
        guard(
            normalizedBaseURL(value.getString("apiBase")) == serverURL,
            "server_identity_mismatch",
        )
        val oidc = value.getJSONObject("oidc")
        guard(oidc.optString("authorizationFlow") == "authorization_code_pkce", "server_auth_insecure")
        val capabilities = value.getJSONArray("capabilities").strings(maximumUTF8Bytes = 64)
        guard(
            "oidc-pkce" in capabilities && "oauth-resource-indicators" in capabilities &&
                "oauth-token-revocation" in capabilities &&
                "resource-session-revocation" in capabilities &&
                "account-without-required-email" in capabilities &&
                "phishing-resistant-step-up" in capabilities &&
                "pairing-v2" in capabilities && "offline-recovery-v1" in capabilities,
            "server_auth_insecure",
        )
        val scopes = oidc.getJSONArray("scopes").strings(maximumUTF8Bytes = 64)
        guard("openid" in scopes && "offline_access" in scopes, "server_auth_insecure")
        val issuer = normalizedIssuer(oidc.getString("issuer"))
        val resource = normalizedBaseURL(oidc.getString("resource"))
        guard(resource == serverURL, "server_identity_mismatch")
        val clientID = oidc.getString("clientId")
        val maximumAccessTokenAgeSeconds = oidc.getInt("maxAccessTokenAgeSeconds")
        val stepUpMaximumAgeSeconds = oidc.getInt("stepUpMaxAgeSeconds")
        guard(clientID.isNotBlank() && clientID.toByteArray().size <= 256, "server_discovery_invalid")
        guard(maximumAccessTokenAgeSeconds in 60..86_400, "server_discovery_invalid")
        guard(stepUpMaximumAgeSeconds in 60..3_600, "server_discovery_invalid")
        return ServiceDiscovery(
            serverURL = serverURL,
            issuer = issuer,
            resource = resource,
            clientID = clientID,
            scopes = scopes,
            maximumAccessTokenAgeSeconds = maximumAccessTokenAgeSeconds,
            stepUpMaximumAgeSeconds = stepUpMaximumAgeSeconds,
            stepUpACRValues = oidc.getJSONArray("stepUpACRValues").strings(
                allowEmpty = true,
                maximumUTF8Bytes = 256,
            ),
        )
    }

    private fun validateOIDCConfiguration(configuration: AuthorizationServiceConfiguration) {
        listOf(configuration.authorizationEndpoint, configuration.tokenEndpoint).forEach { endpoint ->
            val uri = URI(endpoint.toString())
            guard(
                uri.scheme == "https" && uri.host != null && uri.userInfo == null && uri.fragment == null,
                "identity_provider_configuration_invalid",
            )
        }
        val document = configuration.discoveryDoc?.docJson
            ?: throw CloudAuthFailure("identity_provider_configuration_invalid")
        val methods = document.optJSONArray("code_challenge_methods_supported")
            ?: throw CloudAuthFailure("identity_provider_configuration_invalid")
        guard(
            (0 until methods.length()).map(methods::getString).contains("S256"),
            "identity_provider_configuration_invalid",
        )
        secureEndpoint(document.getString("revocation_endpoint"))
    }

    private fun revokeResourceAccessToken(serverURL: String, accessToken: String): Int {
        try {
            val connection = URI("$serverURL/v1/session").toURL()
                .openConnection() as HttpURLConnection
            connection.requestMethod = "DELETE"
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Authorization", "Bearer $accessToken")
            connection.setRequestProperty("X-Snippets-Protocol", "1")
            val status = connection.responseCode
            val body = readBounded(
                if (status == 204) connection.inputStream else connection.errorStream,
                DISCOVERY_MAX_BYTES,
            )
            guard(status != 204 || body.isEmpty(), "credential_revocation_failed")
            return status
        } catch (failure: CloudAuthFailure) {
            throw failure
        } catch (_: Exception) {
            throw CloudAuthFailure("credential_revocation_failed")
        }
    }

    private fun revokeProviderCredentials(
        session: StoredSession,
        plan: CloudCredentialRevocationPlan,
    ) {
        try {
            fun revoke(token: String, hint: String) {
                val values = linkedMapOf(
                    "client_id" to session.clientID,
                    "token" to token,
                    "token_type_hint" to hint,
                )
                val body = values.entries.joinToString("&") { (key, value) ->
                    "${URLEncoder.encode(key, Charsets.UTF_8.name())}=" +
                        URLEncoder.encode(value, Charsets.UTF_8.name())
                }.toByteArray(Charsets.UTF_8)
                val connection = URI(session.revocationEndpoint).toURL()
                    .openConnection() as HttpURLConnection
                connection.requestMethod = "POST"
                connection.connectTimeout = 15_000
                connection.readTimeout = 15_000
                connection.instanceFollowRedirects = false
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(body.size)
                connection.setRequestProperty("Accept", "application/json")
                connection.setRequestProperty(
                    "Content-Type",
                    "application/x-www-form-urlencoded",
                )
                connection.outputStream.use { it.write(body) }
                val status = connection.responseCode
                readBounded(
                    if (status == 200) connection.inputStream else connection.errorStream,
                    DISCOVERY_MAX_BYTES,
                )
                guard(status == 200, "credential_revocation_failed")
            }
            plan.accessTokens.forEach {
                revoke(it, "access_token")
            }
            plan.refreshTokens.forEach {
                revoke(it, "refresh_token")
            }
        } catch (failure: CloudAuthFailure) {
            throw failure
        } catch (_: Exception) {
            throw CloudAuthFailure("credential_revocation_failed")
        }
    }

    private fun makeRevocationJournal(sessions: List<StoredSession>): RevocationJournal {
        val first = sessions.first()
        return RevocationJournal(
            serverURL = first.serverURL,
            issuer = first.issuer,
            resource = first.resource,
            revocationEndpoint = first.revocationEndpoint,
            clientID = first.clientID,
            accessTokens = sessions.map(StoredSession::accessToken).distinct(),
            refreshTokens = sessions.map(StoredSession::refreshToken).distinct(),
        )
    }

    private fun extendRevocationJournalIfPresent(sessions: List<StoredSession>) {
        val first = sessions.first()
        val existing = loadRevocationJournal(first) ?: return
        storeRevocationJournal(existing.copy(
            accessTokens = (existing.accessTokens + sessions.map(StoredSession::accessToken)).distinct(),
            refreshTokens = (existing.refreshTokens + sessions.map(StoredSession::refreshToken)).distinct(),
        ))
    }

    private fun storeRevocationJournal(journal: RevocationJournal) {
        guard(
            journal.accessTokens.size in 1..16 && journal.refreshTokens.size in 1..16,
            "authorization_state_invalid",
        )
        val value = JSONObject()
            .put("schemaVersion", 1)
            .put("serverURL", journal.serverURL)
            .put("issuer", journal.issuer)
            .put("resource", journal.resource)
            .put("revocationEndpoint", journal.revocationEndpoint)
            .put("clientID", journal.clientID)
            .put("accessTokens", JSONArray(journal.accessTokens))
            .put("refreshTokens", JSONArray(journal.refreshTokens))
            .toString()
        guard(value.toByteArray().size <= REVOCATION_MAX_BYTES, "authorization_state_invalid")
        store.write(AUTH_REVOCATION, value)
    }

    private fun loadRevocationJournal(session: StoredSession): RevocationJournal? {
        val raw = store.read(AUTH_REVOCATION) ?: return null
        try {
            guard(raw.toByteArray().size <= REVOCATION_MAX_BYTES, "authorization_state_invalid")
            val value = JSONObject(raw)
            val expected = setOf(
                "schemaVersion", "serverURL", "issuer", "resource",
                "revocationEndpoint", "clientID", "accessTokens", "refreshTokens",
            )
            guard(value.keys().asSequence().toSet() == expected, "authorization_state_invalid")
            guard(value.getInt("schemaVersion") == 1, "authorization_state_invalid")
            val accessTokens = tokenArray(value.getJSONArray("accessTokens"))
            val refreshTokens = tokenArray(value.getJSONArray("refreshTokens"))
            val journal = RevocationJournal(
                serverURL = normalizedBaseURL(value.getString("serverURL")),
                issuer = normalizedIssuer(value.getString("issuer")),
                resource = normalizedBaseURL(value.getString("resource")),
                revocationEndpoint = secureEndpoint(value.getString("revocationEndpoint")),
                clientID = value.getString("clientID"),
                accessTokens = accessTokens,
                refreshTokens = refreshTokens,
            )
            guard(
                journal.serverURL == session.serverURL && journal.issuer == session.issuer &&
                    journal.resource == session.resource &&
                    journal.revocationEndpoint == session.revocationEndpoint &&
                    journal.clientID == session.clientID,
                "authorization_state_invalid",
            )
            return journal
        } catch (failure: CloudAuthFailure) {
            throw failure
        } catch (_: Exception) {
            throw CloudAuthFailure("authorization_state_invalid")
        }
    }

    private fun tokenArray(value: JSONArray): List<String> {
        guard(value.length() in 1..16, "authorization_state_invalid")
        return (0 until value.length()).map(value::getString).also { tokens ->
            tokens.forEach { validateToken(it, "authorization_state_invalid") }
            guard(tokens.distinct().size == tokens.size, "authorization_state_invalid")
        }
    }

    private fun secureEndpoint(raw: String): String {
        val uri = try {
            URI(raw)
        } catch (_: Exception) {
            throw CloudAuthFailure("identity_provider_configuration_invalid")
        }
        guard(
            raw.toByteArray().size <= 2_048 && uri.scheme == "https" && uri.host != null &&
                uri.userInfo == null && uri.fragment == null,
            "identity_provider_configuration_invalid",
        )
        return uri.toASCIIString()
    }

    private fun validateToken(value: String, code: String) {
        guard(
            value.toByteArray().size in 8..16_384 && value.none(Char::isWhitespace),
            code,
        )
    }

    /**
     * Leak-prevention check performed before an access token ever leaves for a
     * sync origin. Signature validation remains the server's job; this token
     * arrived directly from the issuer's HTTPS endpoint and must have one exact
     * RFC 8707 audience equal to the pinned resource.
     */
    private fun validateResourceAudience(accessToken: String, resource: String) {
        val segments = accessToken.split('.', limit = 4)
        guard(segments.size == 3 && segments[1].length <= 32 * 1024, "token_exchange_failed")
        guard(
            segments[1].all { it.isLetterOrDigit() || it == '-' || it == '_' },
            "token_exchange_failed",
        )
        val payload = try {
            Base64.decode(segments[1], Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            throw CloudAuthFailure("token_exchange_failed")
        }
        guard(payload.size <= 24 * 1024, "token_exchange_failed")
        val value = try {
            JSONObject(payload.toString(Charsets.UTF_8)).get("aud")
        } catch (_: Exception) {
            throw CloudAuthFailure("token_exchange_failed")
        }
        val audiences = when (value) {
            is String -> listOf(value)
            is org.json.JSONArray -> value.strings(maximumUTF8Bytes = 2_048)
            else -> emptyList()
        }
        guard(audiences == listOf(resource), "token_exchange_failed")
    }

    private fun configuredServerURL(): String {
        guard(BuildConfig.SNIPPETS_CLOUD_URL.isNotBlank(), "cloud_build_not_configured")
        return normalizedBaseURL(BuildConfig.SNIPPETS_CLOUD_URL)
    }

    private fun configuredRedirectURI(): Uri {
        val value = URI(BuildConfig.SNIPPETS_OAUTH_REDIRECT_URI)
        guard(
            value.scheme == "https" && value.host != null && value.userInfo == null &&
                value.query == null && value.fragment == null &&
                value.path == "/oauth2redirect/android" &&
                !value.host.endsWith(".invalid") && value.host != "invalid",
            "cloud_build_not_configured",
        )
        return Uri.parse(value.toASCIIString())
    }

    private fun normalizedBaseURL(raw: String): String {
        guard(raw.toByteArray().size <= 2_048, "server_url_invalid")
        val uri = URI(raw.trim().trimEnd('/'))
        guard(
            uri.scheme == "https" && uri.host != null && uri.userInfo == null &&
                uri.query == null && uri.fragment == null,
            "server_url_invalid",
        )
        return uri.toASCIIString().trimEnd('/')
    }

    private fun normalizedIssuer(raw: String): String {
        val uri = URI(raw.trim())
        guard(
            uri.scheme == "https" && uri.host != null && uri.userInfo == null &&
                uri.query == null && uri.fragment == null,
            "server_discovery_invalid",
        )
        return uri.toASCIIString()
    }

    private fun readBounded(input: java.io.InputStream?, maximumBytes: Int): ByteArray {
        if (input == null) return ByteArray(0)
        input.use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8_192)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                if (output.size() > maximumBytes - count) {
                    throw CloudAuthFailure("server_discovery_too_large")
                }
                output.write(buffer, 0, count)
            }
            return output.toByteArray()
        }
    }

    private fun org.json.JSONArray.strings(
        allowEmpty: Boolean = false,
        maximumUTF8Bytes: Int = 256,
    ): List<String> =
        (0 until length()).map(::getString).also { values ->
            guard(
                (allowEmpty || values.isNotEmpty()) && values.size <= 16 &&
                    values.toSet().size == values.size &&
                    values.all { it.isNotBlank() && it.toByteArray().size <= maximumUTF8Bytes },
                "server_discovery_invalid",
            )
        }

    private fun guard(condition: Boolean, code: String) {
        if (!condition) throw CloudAuthFailure(code)
    }

    private companion object {
        const val DISCOVERY_MAX_BYTES = 256 * 1024
        const val SESSION_MAX_BYTES = 128 * 1024
        const val REVOCATION_MAX_BYTES = 256 * 1024
        const val REFRESH_EARLY_MILLIS = 60_000L
        const val MIN_TOKEN_LIFETIME_MILLIS = 30_000L
        const val MAX_TOKEN_LIFETIME_MILLIS = 86_460_000L
        const val AUTH_SESSION = "oidc-session.enc"
        const val AUTH_REVOCATION = "oidc-revocation-journal.enc"
        const val LEGACY_AUTH_STATE = "oidc-auth-state.enc"
        const val LEGACY_AUTH_SERVER = "oidc-auth-server.enc"
        const val PENDING = "oidc-pending.enc"
    }
}

class CloudAuthFailure(val code: String) : Exception(code)
