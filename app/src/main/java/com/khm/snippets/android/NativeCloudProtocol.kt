package com.khm.snippets.android

import org.json.JSONObject
import java.net.URI
import java.security.MessageDigest
import java.time.OffsetDateTime
import java.util.Locale
import java.util.UUID

internal data class NativeCloudAuthority(
    val serverURL: String,
    val createAccountEndpoint: String,
    val signInEndpoint: String,
    val refreshEndpoint: String,
    val revokeEndpoint: String,
) {
    /** ADR 0007 endpoints are fixed paths on the pinned origin; discovery does not name them. */
    val deviceRequestsEndpoint: String get() = "$serverURL/v2/auth/device-requests"

    fun deviceClaimEndpoint(requestID: String): String =
        "$deviceRequestsEndpoint/${requireNotNull(nativeCloudUUID(requestID))}/claim"

    companion object {
        const val DEVICE_SIGN_IN_CAPABILITY = "native-device-sign-in-v1"

        /** Account-key discovery plus the device-approved sign-in capability. */
        fun parseWithDeviceSignIn(serverURL: String, value: JSONObject): NativeCloudAuthority {
            val authority = parse(serverURL, value)
            cloudAuthGuard(DEVICE_SIGN_IN_CAPABILITY in capabilityNames(value), "device_sign_in_unavailable")
            return authority
        }

        private fun capabilityNames(value: JSONObject): Set<String> {
            val capabilities = value.getJSONArray("capabilities")
            cloudAuthGuard(capabilities.length() in 1..32, "server_discovery_invalid")
            return (0 until capabilities.length()).map(capabilities::getString).toSet()
        }

        fun forServer(serverURL: String) = NativeCloudAuthority(
            serverURL, "$serverURL/v2/auth/accounts", "$serverURL/v2/auth/sign-in",
            "$serverURL/v2/auth/refresh", "$serverURL/v2/auth/revoke",
        )

        fun parse(serverURL: String, value: JSONObject): NativeCloudAuthority {
            cloudAuthGuard(value.optInt("protocolMajor") == 2, "server_protocol_incompatible")
            cloudAuthGuard(value.optString("apiBase") == "$serverURL/v2", "server_identity_mismatch")
            val names = capabilityNames(value)
            cloudAuthGuard(names.containsAll(setOf("native-account-key-v1", "library-action-proof-v1",
                "pairing-v2", "offline-recovery-v1", "resource-session-revocation")), "server_auth_insecure")
            val native = value.getJSONObject("nativeAuth")
            cloudAuthGuard(native.optString("flow") == "account_key", "server_auth_insecure")
            val expected = forServer(serverURL)
            // The account key and every token are sent only to these exact pinned paths.
            cloudAuthGuard(native.optString("createAccountEndpoint") == expected.createAccountEndpoint &&
                native.optString("signInEndpoint") == expected.signInEndpoint &&
                native.optString("refreshEndpoint") == expected.refreshEndpoint &&
                native.optString("revokeEndpoint") == expected.revokeEndpoint, "server_identity_mismatch")
            return expected
        }
    }
}

/**
 * Server-generated account keys (server ADR 0006). Only the server generates keys; the
 * client normalizes typed input and never sends a key that fails the local check. A key
 * is a sign-in secret: it never enters logs, diagnostics, saved state or backups.
 */
internal object NativeCloudAccountKey {
    const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    const val BODY_LENGTH = 26
    const val LENGTH = BODY_LENGTH + 2
    const val MAX_INPUT_BYTES = 64

    /** Space, tab, line feed, vertical tab, form feed and carriage return. */
    private const val ASCII_WHITESPACE = " \t\n\u000B\u000C\r"
    private val CHECK_DOMAIN = "snippets-account-key-check-v1\n".toByteArray(Charsets.US_ASCII)

    /**
     * Returns the canonical 28-symbol wire form, or null for a local typing error.
     * Separators and ASCII whitespace are removed, ASCII letters are uppercased and the
     * Crockford look-alikes O, I and L are read as 0, 1 and 1 before the check is verified.
     */
    fun normalize(input: String): String? {
        if (input.toByteArray(Charsets.UTF_8).size > MAX_INPUT_BYTES) return null
        val symbols = StringBuilder(LENGTH)
        for (character in input) {
            if (character == '-' || character in ASCII_WHITESPACE) continue
            val upper = if (character in 'a'..'z') character - ('a' - 'A') else character
            val symbol = when (upper) {
                'O' -> '0'
                'I', 'L' -> '1'
                else -> upper
            }
            if (symbol !in ALPHABET || symbols.length == LENGTH) return null
            symbols.append(symbol)
        }
        if (symbols.length != LENGTH) return null
        val canonical = symbols.toString()
        return canonical.takeIf { check(it.substring(0, BODY_LENGTH)) == it.substring(BODY_LENGTH) }
    }

    fun isCanonical(value: String): Boolean = normalize(value) == value

    /** Seven groups of four symbols joined by `-`. */
    fun displayForm(canonical: String): String {
        require(isCanonical(canonical))
        return canonical.chunked(4).joinToString("-")
    }

    internal fun check(body: String): String {
        val digest = MessageDigest.getInstance("SHA-256").run {
            update(CHECK_DOMAIN)
            update(body.toByteArray(Charsets.US_ASCII))
            digest()
        }
        val value = ((digest[0].toInt() and 0xff) shl 2) or ((digest[1].toInt() and 0xff) ushr 6)
        return "${ALPHABET[value ushr 5]}${ALPHABET[value and 31]}"
    }
}

private val NATIVE_CLOUD_ACCOUNT_ID =
    Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

/** Native account IDs are immutable UUIDs; the lowercase form is the stored identity. */
internal fun nativeCloudAccountID(raw: String): String? =
    raw.takeIf(NATIVE_CLOUD_ACCOUNT_ID::matches)?.lowercase(Locale.ROOT)

/** Account ID shown in Settings: the first eight hex digits, uppercase, as `XXXX-XXXX`. */
internal fun nativeCloudAccountIDDisplay(accountID: String): String {
    val prefix = requireNotNull(nativeCloudAccountID(accountID)).take(8).uppercase(Locale.ROOT)
    return "${prefix.take(4)}-${prefix.drop(4)}"
}

/** `POST /v2/auth/accounts`: a new key, returned exactly once, with its first session. */
internal class NativeCloudAccountCreation(
    val accountKey: String,
    val session: NativeCloudTokenResponse,
) {
    override fun toString(): String = "NativeCloudAccountCreation(<redacted>)"

    companion object {
        /** The issued session is journaled for revocation before the key is validated. */
        fun parseAfterJournaling(
            value: JSONObject,
            grantID: String,
            persistIssued: (NativeCloudCredentialGeneration) -> Unit,
        ): NativeCloudAccountCreation {
            val session = value.optJSONObject("session")
                ?: throw CloudAuthFailure("server_response_invalid")
            val token = NativeCloudTokenResponse.parseAfterJournaling(session, grantID,
                persistIssued = persistIssued)
            val key = value.opt("accountKey") as? String
            cloudAuthGuard(key != null && NativeCloudAccountKey.isCanonical(key), "server_response_invalid")
            return NativeCloudAccountCreation(key!!, token)
        }
    }
}

/** Lowercase canonical UUID, or null. */
internal fun nativeCloudUUID(raw: String): String? = runCatching {
    UUID.fromString(raw).toString().takeIf { it.equals(raw, ignoreCase = true) }
}.getOrNull()

private fun nativeCloudEpochSeconds(raw: Any?): Long? = (raw as? String)?.let {
    runCatching { OffsetDateTime.parse(it).toInstant().epochSecond }.getOrNull()
}

private fun JSONObject.memberNames(): Set<String> = keys().asSequence().toSet()

/** `POST /v2/auth/device-requests` result. [pollToken] is a claim credential. */
internal class NativeCloudDeviceRequest(
    val requestID: String,
    val pollToken: String,
    val expiresAtEpochSeconds: Long,
) {
    override fun toString(): String = "NativeCloudDeviceRequest(<redacted>)"

    companion object {
        fun parse(value: JSONObject, nowEpochSeconds: Long = System.currentTimeMillis() / 1_000): NativeCloudDeviceRequest {
            cloudAuthGuard(value.memberNames() == setOf("requestId", "pollToken", "expiresAt"),
                "server_response_invalid")
            val requestID = (value.opt("requestId") as? String)?.let(::nativeCloudUUID)
            val pollToken = value.opt("pollToken") as? String
            val expiresAt = nativeCloudEpochSeconds(value.opt("expiresAt"))
            cloudAuthGuard(requestID != null && pollToken != null &&
                LibraryKeyBootstrap.isDevicePollToken(pollToken) && expiresAt != null &&
                expiresAt > nowEpochSeconds - 30 && expiresAt <= nowEpochSeconds + 630,
                "server_response_invalid")
            return NativeCloudDeviceRequest(requestID!!, pollToken!!, expiresAt!!)
        }
    }
}

/** `POST /v2/auth/device-requests/{id}/claim`: exactly `pending` or `approved` members. */
internal sealed class NativeCloudDeviceClaim {
    object Pending : NativeCloudDeviceClaim()

    class Approved(
        val spaceID: String,
        val pairingID: String,
        val session: NativeCloudTokenResponse,
    ) : NativeCloudDeviceClaim() {
        override fun toString(): String = "NativeCloudDeviceClaim.Approved(<redacted>)"
    }

    companion object {
        /**
         * An approved claim's session is journaled for revocation before any other member
         * is validated, so a malformed response never orphans an issued session family.
         */
        fun parseAfterJournaling(
            value: JSONObject,
            grantID: String,
            requestExpiresAtEpochSeconds: Long,
            persistIssued: (NativeCloudCredentialGeneration) -> Unit,
        ): NativeCloudDeviceClaim {
            val session = value.optJSONObject("session")
            val token = session?.let {
                NativeCloudTokenResponse.parseAfterJournaling(it, grantID, persistIssued = persistIssued)
            }
            val expiresAt = nativeCloudEpochSeconds(value.opt("expiresAt"))
            cloudAuthGuard(expiresAt != null &&
                kotlin.math.abs(expiresAt - requestExpiresAtEpochSeconds) <= 1, "server_response_invalid")
            return when (value.opt("state")) {
                "pending" -> {
                    cloudAuthGuard(value.memberNames() == setOf("state", "expiresAt"), "server_response_invalid")
                    Pending
                }
                "approved" -> {
                    cloudAuthGuard(value.memberNames() ==
                        setOf("state", "expiresAt", "spaceId", "pairingId", "session"), "server_response_invalid")
                    val spaceID = (value.opt("spaceId") as? String)?.let(::nativeCloudUUID)
                    val pairingID = (value.opt("pairingId") as? String)?.let(::nativeCloudUUID)
                    cloudAuthGuard(spaceID != null && pairingID != null && token != null,
                        "server_response_invalid")
                    Approved(spaceID!!, pairingID!!, token!!)
                }
                else -> throw CloudAuthFailure("server_response_invalid")
            }
        }
    }
}

internal data class NativeCloudTokenResponse(
    val accessToken: String,
    val refreshToken: String,
    val expiresIn: Int,
    val accountID: String,
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
            val id = nativeCloudAccountID(account.getString("id"))
            cloudAuthGuard(id != null && (expectedAccountID == null || id == expectedAccountID),
                "authorization_response_mismatch")
            return NativeCloudTokenResponse(access, refresh, expires, id!!)
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
