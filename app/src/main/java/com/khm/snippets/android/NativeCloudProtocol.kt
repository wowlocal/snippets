package com.khm.snippets.android

import org.json.JSONObject
import java.net.URI

internal data class NativeCloudAuthority(
    val serverURL: String,
    val startEndpoint: String,
    val verifyEndpoint: String,
    val refreshEndpoint: String,
    val revokeEndpoint: String,
) {
    companion object {
        fun forServer(serverURL: String) = NativeCloudAuthority(
            serverURL, "$serverURL/v2/auth/email/start", "$serverURL/v2/auth/email/verify",
            "$serverURL/v2/auth/refresh", "$serverURL/v2/auth/revoke",
        )

        fun parse(serverURL: String, value: JSONObject): NativeCloudAuthority {
            cloudAuthGuard(value.optInt("protocolMajor") == 2, "server_protocol_incompatible")
            cloudAuthGuard(value.optString("apiBase") == "$serverURL/v2", "server_identity_mismatch")
            val capabilities = value.getJSONArray("capabilities")
            cloudAuthGuard(capabilities.length() in 1..32, "server_discovery_invalid")
            val names = (0 until capabilities.length()).map(capabilities::getString).toSet()
            cloudAuthGuard(names.containsAll(setOf("native-email-code-v1", "library-action-proof-v1",
                "pairing-v2", "offline-recovery-v1", "resource-session-revocation")), "server_auth_insecure")
            val native = value.getJSONObject("nativeAuth")
            cloudAuthGuard(native.optString("flow") == "email_code", "server_auth_insecure")
            val expected = forServer(serverURL)
            cloudAuthGuard(native.optString("startEndpoint") == expected.startEndpoint &&
                native.optString("verifyEndpoint") == expected.verifyEndpoint &&
                native.optString("refreshEndpoint") == expected.refreshEndpoint &&
                native.optString("revokeEndpoint") == expected.revokeEndpoint, "server_identity_mismatch")
            return expected
        }
    }
}

data class CloudEmailChallenge(
    val challengeID: String,
    val expiresIn: Int,
    val resendAfter: Int,
    val codeLength: Int,
) {
    internal companion object {
        fun parse(value: JSONObject): CloudEmailChallenge {
            val id = value.getString("challengeId")
            cloudAuthGuard(id.toByteArray().size in 16..256 && id.none(Char::isWhitespace), "server_response_invalid")
            val expires = value.getInt("expiresIn")
            val resend = value.getInt("resendAfter")
            cloudAuthGuard(expires in 60..600 && resend in 1..600 &&
                value.getInt("codeLength") == 6, "server_response_invalid")
            return CloudEmailChallenge(id, expires, resend, 6)
        }
    }
}

internal data class NativeCloudTokenResponse(
    val accessToken: String,
    val refreshToken: String,
    val expiresIn: Int,
    val accountID: String,
    val email: String,
) {
    companion object {
        fun parseAfterJournaling(
            value: JSONObject,
            grantID: String,
            previousRefreshToken: String? = null,
            expectedAccountID: String? = null,
            persistIssued: (NativeCloudCredentialGeneration) -> Unit,
        ): NativeCloudTokenResponse {
            persistIssued(nativeCloudIssuedGeneration(value, grantID))
            return parse(value, previousRefreshToken, expectedAccountID)
        }

        fun parse(value: JSONObject, previousRefreshToken: String? = null,
                  expectedAccountID: String? = null): NativeCloudTokenResponse {
            cloudAuthGuard(value.optString("token_type").equals("Bearer", true), "token_exchange_failed")
            val access = value.getString("access_token")
            val refresh = value.getString("refresh_token")
            validateNativeCloudToken(access)
            validateNativeCloudToken(refresh)
            cloudAuthGuard(refresh != previousRefreshToken, "refresh_token_not_rotated")
            val expires = value.getInt("expires_in")
            cloudAuthGuard(expires in 1..300, "token_exchange_failed")
            val account = value.getJSONObject("account")
            val id = account.getString("id")
            val email = account.getString("email")
            cloudAuthGuard(id.toByteArray().size in 1..256 && id.none(Char::isISOControl) &&
                (expectedAccountID == null || id == expectedAccountID), "authorization_response_mismatch")
            cloudAuthGuard(email.toByteArray().size in 3..254 && email.contains('@') &&
                email.none { it.isWhitespace() || it.isISOControl() }, "authorization_response_mismatch")
            return NativeCloudTokenResponse(access, refresh, expires, id, email)
        }
    }
}

internal data class NativeCloudCredentialGeneration(
    val grantID: String,
    val accessToken: String,
    val refreshToken: String,
)

/** Extract only revocable credentials before validating any account or lifetime metadata. */
internal fun nativeCloudIssuedGeneration(value: JSONObject, grantID: String): NativeCloudCredentialGeneration {
    val access = value.getString("access_token")
    val refresh = value.getString("refresh_token")
    validateNativeCloudToken(access)
    validateNativeCloudToken(refresh)
    return NativeCloudCredentialGeneration(grantID, access, refresh)
}

internal data class NativeCloudRefreshCleanupPlan(
    val accessTokensToRetire: List<String>,
    val refreshTokensToRetire: List<String>,
    val discardStoredSession: Boolean,
)

internal fun nativeCloudRefreshCleanupPlan(
    current: NativeCloudCredentialGeneration?,
    previous: NativeCloudCredentialGeneration,
    issued: NativeCloudCredentialGeneration,
): NativeCloudRefreshCleanupPlan? {
    if (previous.grantID != issued.grantID ||
        (current != null && current != previous && current != issued)) return null
    val committed = issued.refreshToken != previous.refreshToken && current == issued
    return if (committed) NativeCloudRefreshCleanupPlan(
        listOf(previous.accessToken).filter { it != issued.accessToken }, emptyList(), false,
    ) else NativeCloudRefreshCleanupPlan(listOf(issued.accessToken), listOf(issued.refreshToken), true)
}

internal fun nativeCloudRetryAfter(raw: String?): Int? = raw?.toLongOrNull()
    ?.coerceIn(1L, 86_400L)?.toInt()

/** Refresh revokes a family: never revoke an earlier refresh token in the kept grant. */
internal fun nativeCloudReplacementCleanupPlan(
    current: NativeCloudCredentialGeneration?,
    generations: List<NativeCloudCredentialGeneration>,
): CloudCredentialReplacementCleanupPlan? {
    if (generations.isEmpty() || (current != null && current !in generations)) return null
    return CloudCredentialReplacementCleanupPlan(
        generations.map { it.accessToken }.distinct().filter { it != current?.accessToken },
        generations.filter { it.grantID != current?.grantID }.map { it.refreshToken }.distinct(),
    )
}

internal fun validateNativeCloudToken(value: String) {
    cloudAuthGuard(value.toByteArray().size in 8..16_384 &&
        value.none { it.isWhitespace() || it.isISOControl() }, "authorization_state_invalid")
}

internal fun nativeCloudServerURL(raw: String): String {
    val uri = try { URI(raw.trim().trimEnd('/')) } catch (_: Exception) {
        throw CloudAuthFailure("server_url_invalid")
    }
    cloudAuthGuard(raw.toByteArray().size <= 2_048 && uri.scheme == "https" &&
        uri.host != null && uri.userInfo == null && uri.query == null && uri.fragment == null &&
        uri.path.orEmpty().isEmpty(), "server_url_invalid")
    return uri.toASCIIString().trimEnd('/')
}

internal fun cloudAuthGuard(condition: Boolean, code: String) {
    if (!condition) throw CloudAuthFailure(code)
}
