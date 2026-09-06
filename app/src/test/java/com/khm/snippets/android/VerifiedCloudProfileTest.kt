package com.khm.snippets.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.interfaces.RSAPublicKey
import java.util.Base64

class VerifiedCloudProfileTest {
    @Test fun verifiesSignatureNonceAudienceAndResourceIdentity() {
        val key = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val pub = key.public as RSAPublicKey
        fun encode(bytes: ByteArray) = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        fun integer(value: java.math.BigInteger) = value.toByteArray().let { if (it[0] == 0.toByte()) it.drop(1).toByteArray() else it }
        val jwks = JSONObject().put("keys", JSONArray().put(JSONObject().put("kid", "fixture")
            .put("kty", "RSA").put("alg", "RS256").put("n", encode(integer(pub.modulus)))
            .put("e", encode(integer(pub.publicExponent)))))
        fun token(aud: String, sub: String = "account-a", nonce: String = "nonce-a"): String {
            val now = System.currentTimeMillis()/1000
            val payload = JSONObject().put("iss", "https://identity.example/oidc").put("aud", aud)
                .put("sub", sub).put("nonce", nonce).put("iat", now).put("exp", now + 300)
                .put("name", "Test Account").put("email", "fixture@example.test").put("email_verified", true)
            val message = encode("{\"alg\":\"RS256\",\"kid\":\"fixture\"}".toByteArray()) + "." + encode(payload.toString().toByteArray())
            val signature = Signature.getInstance("SHA256withRSA").run { initSign(key.private); update(message.toByteArray()); sign() }
            return message + "." + encode(signature)
        }
        val id = token("native-client"); val access = token("https://sync.example")
        fun verify(identity: String = id, resource: String = access, nonce: String = "nonce-a") =
            VerifiedCloudProfile.verify(identity, resource, jwks, "https://identity.example/oidc", "native-client", "https://sync.example", nonce)
        assertEquals("Test Account", verify().getString("name"))
        assertThrows(Exception::class.java) { verify(nonce = "nonce-b") }
        assertThrows(Exception::class.java) { verify(resource = token("https://sync.example", "account-b")) }
        assertThrows(Exception::class.java) { verify(identity = token("other-client")) }
        assertThrows(Exception::class.java) { verify(identity = id.dropLast(5) + "AAAAA") }
    }
}
