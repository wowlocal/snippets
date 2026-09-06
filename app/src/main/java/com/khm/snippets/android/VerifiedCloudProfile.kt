package com.khm.snippets.android

import org.json.JSONObject
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.RSAPublicKeySpec
import java.util.Base64

/** Display-only identity; never a key lookup or account-linking authority. */
internal object VerifiedCloudProfile {
    fun verify(idToken: String, accessToken: String, keys: JSONObject, issuer: String,
               clientID: String, resource: String, nonce: String): JSONObject {
        val identity = claims(idToken, keys, issuer, clientID)
        val access = claims(accessToken, keys, issuer, resource)
        require(identity.getString("nonce") == nonce)
        val subject = identity.getString("sub")
        require(subject.isNotBlank() && subject.toByteArray().size <= 256 && access.getString("sub") == subject)
        fun display(key: String, limit: Int): String? = identity.optString(key).takeIf {
            it.isNotBlank() && it.toByteArray().size <= limit && it.none(Char::isISOControl)
        }
        return JSONObject().put("issuer", issuer).put("subject", subject)
            .put("name", display("name", 256))
            .put("email", if (identity.optBoolean("email_verified")) display("email", 320) else null)
    }

    private fun claims(token: String, jwks: JSONObject, issuer: String, audience: String): JSONObject {
        val parts = token.split('.')
        require(parts.size == 3 && token.toByteArray().size <= 16_384)
        val header = JSONObject(decode(parts[0]).toString(Charsets.UTF_8))
        val algorithm = header.getString("alg")
        require(algorithm in listOf("RS256", "ES256") && !header.has("crit") && !header.has("b64"))
        val keys = jwks.getJSONArray("keys")
        require(keys.length() in 1..16)
        val candidates = (0 until keys.length()).map(keys::getJSONObject).filter {
            it.optString("kid") == header.getString("kid") &&
                (!it.has("use") || it.getString("use") == "sig") &&
                (!it.has("alg") || it.getString("alg") == algorithm)
        }
        require(candidates.size == 1)
        val key = candidates.single()
        var signature = decode(parts[2])
        val publicKey = if (algorithm == "RS256") {
            require(key.getString("kty") == "RSA")
            val n = decode(key.getString("n")); val e = decode(key.getString("e"))
            require(n.size in 256..512 && e.size in 1..4)
            KeyFactory.getInstance("RSA").generatePublic(RSAPublicKeySpec(BigInteger(1, n), BigInteger(1, e)))
        } else {
            require(key.getString("kty") == "EC" && key.getString("crv") == "P-256" && signature.size == 64)
            val x = decode(key.getString("x")); val y = decode(key.getString("y"))
            require(x.size == 32 && y.size == 32)
            val params = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
                .getParameterSpec(ECParameterSpec::class.java)
            fun integer(bytes: ByteArray): ByteArray {
                val value = BigInteger(1, bytes).toByteArray()
                return byteArrayOf(2, value.size.toByte()) + value
            }
            val pair = integer(signature.copyOfRange(0, 32)) + integer(signature.copyOfRange(32, 64))
            signature = byteArrayOf(0x30, pair.size.toByte()) + pair
            KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, x), BigInteger(1, y)), params))
        }
        require(Signature.getInstance(if (algorithm == "RS256") "SHA256withRSA" else "SHA256withECDSA").run {
            initVerify(publicKey); update("${parts[0]}.${parts[1]}".toByteArray(Charsets.US_ASCII)); verify(signature)
        })
        val value = JSONObject(decode(parts[1]).toString(Charsets.UTF_8))
        val now = System.currentTimeMillis() / 1000
        require(value.getString("iss") == issuer && value.getLong("exp") > now && value.getLong("iat") <= now + 60)
        require(value.optLong("nbf", 0) <= now + 60)
        val audiences = value.optJSONArray("aud")?.let { array -> (0 until array.length()).map(array::getString) }
            ?: listOf(value.getString("aud"))
        require(audience in audiences && (audiences.size == 1 || value.optString("azp") == audience))
        return value
    }
    private fun decode(value: String): ByteArray {
        require(value.matches(Regex("[A-Za-z0-9_-]+")))
        val data = Base64.getUrlDecoder().decode(value)
        require(Base64.getUrlEncoder().withoutPadding().encodeToString(data) == value)
        return data
    }
}
