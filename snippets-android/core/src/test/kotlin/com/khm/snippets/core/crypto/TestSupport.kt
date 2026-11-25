package com.khm.snippets.core.crypto

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.security.MessageDigest
import java.util.UUID
import kotlin.test.assertEquals

// Shared by the crypto and canonical test packages. All data here is fictional public test data.

/**
 * Test resources. A vector file is one JSON document on the test classpath; adding one is
 * dropping it under `src/test/resources/` and reading it with [json] (or [optionalJson]
 * while a file is still on its way, e.g. the Swift-emitted ones under `vectors/swift/`).
 */
internal object Fixtures {

    fun bytes(path: String): ByteArray = optionalBytes(path) ?: error("missing test resource $path")

    fun optionalBytes(path: String): ByteArray? =
        Fixtures::class.java.classLoader.getResourceAsStream(path)?.use { it.readBytes() }

    fun text(path: String): String = String(bytes(path), Charsets.UTF_8)

    fun json(path: String): JsonObject = Json.parseToJsonElement(text(path)).jsonObject

    /** `null` when the file is not there yet, so a test can skip instead of failing. */
    fun optionalJson(path: String): JsonObject? =
        optionalBytes(path)?.let { Json.parseToJsonElement(String(it, Charsets.UTF_8)).jsonObject }

    /** A fixture copied byte for byte from `snippets-linux/tests/fixtures/`. */
    fun linux(name: String): JsonObject = json("fixtures/linux/$name")
}

internal fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content
internal fun JsonObject.long(key: String): Long = getValue(key).jsonPrimitive.content.toLong()
internal fun JsonObject.obj(key: String): JsonObject = getValue(key).jsonObject
internal fun JsonObject.array(key: String): JsonArray = getValue(key).jsonArray
internal fun JsonElement.string(key: String): String = jsonObject.string(key)

internal fun unhex(text: String): ByteArray = Bytes.fromHex(text) ?: error("not hex: $text")
internal fun ByteArray.hex(): String = Bytes.toHex(this)
internal fun utf8(text: String): ByteArray = text.toByteArray(Charsets.UTF_8)

/** [count] copies of [byte]. */
internal fun filled(byte: Int, count: Int): ByteArray = ByteArray(count) { byte.toByte() }

/** `start, start + 1, …` modulo 256. */
internal fun counting(start: Int, count: Int): ByteArray = ByteArray(count) { (start + it).toByte() }

internal fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).hex()

/** A string from the hex of its UTF-16 code units, so a vector can carry unpaired or decomposed text exactly. */
internal fun fromUtf16Hex(text: String): String =
    String(CharArray(text.length / 4) { text.substring(it * 4, it * 4 + 4).toInt(16).toChar() })

internal fun assertBytes(expected: ByteArray, actual: ByteArray, message: String? = null) {
    assertEquals(expected.hex(), actual.hex(), message)
}

/** Ids laid out so a test can say "record 0" and "record 1" and mean it (as in `CryptoTests.swift`). */
internal fun recordId(index: Int): UUID = UUID.fromString("00000000-0000-4000-8000-%012x".format(index))

/**
 * The xorshift64 generator of the Swift tests (`SeededRandom`), so a property failure
 * reproduces from its seed and the same seeds exercise the same inputs on both platforms.
 */
internal class SeededRandom(seed: Long) {
    private var state: Long = if (seed == 0L) -0x61c8864680b583ebL else seed   // 0x9E3779B97F4A7C15

    fun next(): Long {
        state = state xor (state shl 13)
        state = state xor (state ushr 7)
        state = state xor (state shl 17)
        return state
    }

    fun byte(): Byte = next().toByte()

    fun bytes(count: Int): ByteArray = ByteArray(count) { byte() }

    /** Fisher-Yates driven by this generator. */
    fun <T> shuffled(items: List<T>): List<T> {
        val out = items.toMutableList()
        for (index in out.indices.reversed()) {
            if (index == 0) break
            val other = java.lang.Long.remainderUnsigned(next(), (index + 1).toLong()).toInt()
            val swap = out[index]
            out[index] = out[other]
            out[other] = swap
        }
        return out
    }
}

/** A distinct, predictable nonce per call: eleven zero bytes and a counter. */
internal class CountedNonces {
    var count = 0
        private set

    val source = NonceSource {
        count += 1
        ByteArray(SnippetCrypto.NONCE_BYTE_COUNT).also { it[it.size - 1] = count.toByte() }
    }
}

/** The one nonce nobody may ship: the same twelve bytes every time. Visible here, on purpose. */
internal fun stationaryNonces(byte: Int = 0x5A): NonceSource =
    NonceSource { filled(byte, SnippetCrypto.NONCE_BYTE_COUNT) }

internal fun fixedNonce(nonce: ByteArray): NonceSource = NonceSource { nonce.copyOf() }

/**
 * Replays the nonce inside a known envelope. Every open-direction vector carries its
 * nonce, so sealing the same plaintext with it must reproduce the envelope text exactly.
 */
internal fun nonceOf(envelope: String): NonceSource = fixedNonce(SealedEnvelope.parse(envelope).nonce)

/**
 * Envelope surgery on the decoded bytes. Flipping a base64 character instead could change
 * padding bits and produce a length change rather than the single-bit edit a test means.
 */
internal fun rebuilt(
    envelope: String,
    version: String? = null,
    nonce: ((ByteArray) -> Unit)? = null,
    sealed: ((ByteArray) -> Unit)? = null,
): String {
    val parsed = SealedEnvelope.parse(envelope)
    val nonceBytes = parsed.nonce
    val sealedBytes = parsed.sealed
    nonce?.invoke(nonceBytes)
    sealed?.invoke(sealedBytes)
    return SealedEnvelope(version ?: parsed.version, nonceBytes, sealedBytes).text
}

internal fun flippingFirstBit(data: ByteArray) {
    data[0] = (data[0].toInt() xor 0x01).toByte()
}

internal fun flippingLastBit(data: ByteArray) {
    data[data.size - 1] = (data[data.size - 1].toInt() xor 0x01).toByte()
}

/**
 * The golden vectors emitted by `tools/swift-interop` from the unmodified Swift sources
 * (`src/test/resources/vectors/swift/`). The files are never edited here.
 */
internal object SwiftVectors {

    private val manifest: JsonObject by lazy { Fixtures.json("vectors/swift/sealed/MANIFEST.json").obj("files") }

    /** The cases of a deterministic file, e.g. `sealed("V03-record-seal")`, checked against the manifest's count. */
    fun sealed(name: String): List<JsonObject> {
        val file = Fixtures.json("vectors/swift/sealed/$name.json")
        assertEquals("snippets-swift-interop/$name/v1", file.string("format"))
        val cases = file.array("cases").map { it.jsonObject }
        assertEquals(manifest.obj("$name.json").long("cases").toInt(), cases.size, "$name: case count")
        assertEquals(cases.size, cases.map { it.string("name") }.toSet().size, "$name: case names are unique")
        return cases
    }

    /** `"ok:<value>"` or `"error:<Swift Type.case>"`, as a vector case records an outcome. */
    fun expectedOutcome(case: JsonObject): String =
        if ("ok" in case) "ok:" + case.string("ok") else "error:" + case.string("error")

    /** Runs [block] and renders what happened the way [expectedOutcome] does. */
    fun outcome(block: () -> String): String = try {
        "ok:" + block()
    } catch (failure: Exception) {
        "error:" + swiftName(failure)
    }

    /** The Swift spelling of a failure, `Type.case`. Anything that is not one of the ported failures is rethrown. */
    fun swiftName(failure: Exception): String {
        val type = when (failure) {
            is SnippetCrypto.Failure -> "SnippetCrypto.Failure"
            is PassphraseKdf.Failure -> "PassphraseKDF.Failure"
            is KeyWrap.Failure -> "KeyWrap.Failure"
            is RecoveryKey.Failure -> "RecoveryKey.Failure"
            is com.khm.snippets.core.canonical.CanonicalJson.Failure -> "CanonicalJSON.Failure"
            else -> throw failure
        }
        val case = when (val name = failure::class.java.simpleName) {
            "InvalidUtf8" -> "invalidUTF8"
            else -> name.replaceFirstChar { it.lowercaseChar() }
        }
        return "$type.$case"
    }
}

/**
 * A `{"text", "utf8Hex"}` pair: the text, after checking that it reached this test with the
 * exact bytes Swift had (normalisation form and invisible characters included).
 */
internal fun JsonObject.exactText(key: String): String {
    val pair = obj(key)
    val text = pair.string("text")
    assertEquals(pair.string("utf8Hex"), Utf8.encode(text).hex(), "the text of \"$key\" changed on its way into the test")
    return text
}
