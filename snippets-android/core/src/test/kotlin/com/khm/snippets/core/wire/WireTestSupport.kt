package com.khm.snippets.core.wire

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.AesGcm
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.NonceSource
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.sync.transport.SyncTokenCodingFailure
import java.util.UUID

// Shared by the wire and sync test packages. Everything here is fictional public test data.

/** The fixtures of `Tests/Core/WireTests.swift`. Nothing may depend on when the suite ran. */
internal object WireFixtures {

    /** `Date(timeIntervalSince1970: 1_785_312_000)` as seconds since 2001. */
    const val EPOCH: Double = 807_004_800.0

    fun at(seconds: Double): Double = EPOCH + seconds

    /** Ids laid out so their text order is `id(0) < id(1) < …`. */
    fun id(index: Int): UUID = UUID.fromString("00000000-0000-4000-8000-%012x".format(index))

    const val THIS_DEVICE: String = "aabbccdd"

    fun clock(wallMs: Long, counter: Int = 0, device: String = THIS_DEVICE): Hlc = Hlc.of(wallMs, counter, device)

    fun snippet(
        index: Int,
        name: String = "Signature",
        keyword: String = "sig",
        content: String = "Best,\nMike",
        tags: List<String> = listOf("email", "work"),
        isEnabled: Boolean = true,
        isPinned: Boolean = false,
        createdAt: Double = 0.0,
        updatedAt: Double = 0.0,
    ): Snippet = Snippet(
        id = id(index), name = name, keyword = keyword, content = content, tags = tags,
        isEnabled = isEnabled, isPinned = isPinned, createdAt = at(createdAt), updatedAt = at(updatedAt),
    )

    /** The envelope's ten-key object, parsed back from its canonical bytes. */
    fun canonicalObject(envelope: SyncEnvelope): Map<String, JsonValue> =
        CanonicalJson.parse(envelope.canonicalBytes()).objectOrNull ?: error("an envelope is an object")

    /**
     * Recomputes the self-hash after a test changed one of the nine covered members. This
     * models bytes emitted by another implementation, without going through today's
     * normalising constructors.
     */
    fun canonicalBytesRefreshingHash(original: Map<String, JsonValue>): ByteArray {
        val members = LinkedHashMap(original)
        members.remove("hash")
        members["hash"] = JsonValue.of(SyncEnvelope.sha256Hex(CanonicalJson.encode(JsonValue.Object(members))))
        return CanonicalJson.encode(JsonValue.Object(members))
    }

    fun bytes(members: Map<String, JsonValue>): ByteArray = CanonicalJson.encode(JsonValue.Object(members))

    fun utf8(text: String): ByteArray = text.toByteArray(Charsets.UTF_8)

    fun unhex(text: String): ByteArray = Bytes.fromHex(text) ?: error("not hex")

    fun filled(byte: Int, count: Int): ByteArray = ByteArray(count) { byte.toByte() }

    /** A nonce source that hands out one fixed nonce, for vectors only. */
    fun fixedNonce(nonce: ByteArray): NonceSource = NonceSource { nonce.copyOf() }
}

/**
 * A minimal conformer (`TestSealer` in `WireTests.swift`), so the wire tests exercise the
 * seam and not `SnippetCrypto`'s internals: AES-GCM with a random nonce, the combined
 * `nonce ‖ ciphertext ‖ tag` form, and [WireIdentity.associatedData] as associated data.
 */
internal class TestSealer(seed: Int = 7) : BlobSealer {
    private val key = WireFixtures.filled(seed, 32)

    override fun seal(plaintext: ByteArray, identity: WireIdentity): ByteArray =
        AesGcm.sealCombined(key, Bytes.random(AesGcm.NONCE_BYTES), plaintext, identity.associatedData())

    override fun open(ciphertext: ByteArray, identity: WireIdentity): ByteArray =
        AesGcm.openCombined(key, ciphertext, identity.associatedData())
            ?: throw SnippetCrypto.Failure.AuthenticationFailed()
}

/** `PassthroughRecordVersionSealer` in `SyncRecordCASTests.swift`: the blob is the canonical bytes. */
internal class PassthroughSealer : BlobSealer {
    override fun seal(plaintext: ByteArray, identity: WireIdentity): ByteArray = plaintext.copyOf()
    override fun open(ciphertext: ByteArray, identity: WireIdentity): ByteArray = ciphertext.copyOf()
}

/** The shipping sealer with a keyring made in the test. */
internal fun productionSealer(seed: Int = 3): SnippetCryptoSealer = SnippetCryptoSealer(
    keyring = SnippetCrypto.Keyring(WireFixtures.filled(seed, 32), WireFixtures.filled(0xA5, 16)),
    scopeId = "test-scope",
)

/** The xorshift64 of the Swift suite, so a failure reproduces from its seed. */
internal class WireRandom(seed: Long) {
    private var state: Long = if (seed == 0L) -0x61C8864680B583EBL else seed

    fun next(): Long {
        state = state xor (state shl 13)
        state = state xor (state ushr 7)
        state = state xor (state shl 17)
        return state
    }

    fun int(upperBound: Int): Int =
        if (upperBound <= 0) 0 else java.lang.Long.remainderUnsigned(next(), upperBound.toLong()).toInt()

    fun bool(): Boolean = next() and 1L == 0L

    fun <T> pick(options: List<T>): T = options[int(options.size)]

    fun bytes(count: Int): ByteArray = ByteArray(count) { next().toByte() }

    fun uuid(): UUID = UUID(next(), next())
}

/**
 * The name the Swift vector tool prints for what a call threw: `<Type>.<case>` for the
 * typed errors, `NSError` for Foundation's own.
 */
internal fun swiftErrorName(error: Throwable): String = when (error) {
    is SyncEnvelope.Failure -> "SyncEnvelope.Failure." + caseName(error)
    is CanonicalJson.Failure -> "CanonicalJSON.Failure." + caseName(error)
    is SnippetCrypto.Failure -> "SnippetCrypto.Failure." + caseName(error)
    is SyncKeyMaterial.MalformedMaterial -> "SyncKeyStore.Failure.malformedMaterial"
    is PortableKeyBundle.Failure.InvalidFormat -> "LibraryKeyBootstrap.Failure.invalidFormat"
    is PortableKeyBundle.Failure.Undecodable -> "NSError"
    is SyncTokenCodingFailure -> "DecodingError"
    else -> error.javaClass.name
}

private fun caseName(error: Throwable): String {
    val name = error.javaClass.simpleName
    val swift = name.replaceFirstChar { it.lowercaseChar() }
    // Swift spells these two with the acronym in capitals.
    return when (swift) {
        "invalidUtf8" -> "invalidUTF8"
        else -> swift
    }
}

/** What [block] threw, as [swiftErrorName]; fails the test when it returned normally. */
internal fun swiftErrorOf(block: () -> Unit): String {
    try {
        block()
    } catch (error: Exception) {
        return swiftErrorName(error)
    }
    throw AssertionError("expected a failure, and the call returned normally")
}
