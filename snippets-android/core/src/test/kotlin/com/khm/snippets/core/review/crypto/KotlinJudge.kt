package com.khm.snippets.core.review.crypto

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.canonical.SwiftDouble
import com.khm.snippets.core.crypto.Base64Std
import com.khm.snippets.core.crypto.Base64Url
import com.khm.snippets.core.crypto.DeterministicUuid
import com.khm.snippets.core.crypto.KeyWrap
import com.khm.snippets.core.crypto.NonceSource
import com.khm.snippets.core.crypto.Padding
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.RecoveryKey
import com.khm.snippets.core.crypto.SealedEnvelope
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.review.crypto.ReviewCrypto.hex
import com.khm.snippets.core.review.crypto.ReviewCrypto.text
import com.khm.snippets.core.review.crypto.ReviewCrypto.unhex
import com.khm.snippets.core.text.FoundationText
import java.util.UUID

/**
 * The Kotlin port's answer to one recorder line, in the recorder's own spelling
 * (`judge` in the Swift recorder). Only the declared failure types become `err:`; anything
 * else that escapes is reported as `THROW:<class>` and can never equal a Swift verdict.
 */
internal object KotlinJudge {

    /** Kinds whose Swift verdict is a ciphertext drawn with a random nonce: compared by opening, not by text. */
    val sealingKinds = setOf("rec-seal", "kw-wrap", "pw-wrap")

    fun judge(fields: List<String>): String = try {
        answer(fields)
    } catch (failure: SnippetCrypto.Failure) {
        error("SnippetCrypto", failure)
    } catch (failure: KeyWrap.Failure) {
        error("KeyWrap", failure)
    } catch (failure: PassphraseKdf.Failure) {
        error("PassphraseKDF", failure)
    } catch (failure: RecoveryKey.Failure) {
        error("RecoveryKey", failure)
    } catch (failure: CanonicalJson.Failure) {
        error("CanonicalJSON", failure)
    } catch (escaped: Throwable) {
        "THROW:${escaped.javaClass.name}"
    }

    /**
     * `null` when the port agrees with the recorded Swift [expected] verdict, otherwise what
     * the port did instead.
     */
    fun disagreement(fields: List<String>, expected: String): String? {
        if (fields[0] in sealingKinds && expected.startsWith("ok:")) {
            val opened = try {
                openSwiftSealed(fields, expected.removePrefix("ok:"))
            } catch (escaped: Throwable) {
                "THROW:${escaped.javaClass.name}:${escaped.message}"
            }
            return if (opened == "same") null else opened
        }
        val actual = judge(fields)
        if (fields[0] in sealingKinds && actual.startsWith("ok:")) return "sealed where Swift refused"
        return if (actual == expected) null else actual
    }

    private fun error(type: String, failure: Exception): String = "err:$type:${hex(failure.message ?: "")}"

    private fun keyring(key: String, salt: String) = SnippetCrypto.Keyring(unhex(key), unhex(salt))

    private fun context(scope: String, id: String, deleted: String) =
        SnippetCrypto.RecordContext(text(scope), UUID.fromString(id), deleted == "1")

    private fun purpose(raw: String): KeyWrap.Purpose = KeyWrap.Purpose.entries.first { it.rawValue == raw }

    private fun answer(f: List<String>): String = when (f[0]) {
        "canon" -> canonical(unhex(f[1]))
        "b64url" -> Base64Url.decode(text(f[1]))?.let { "ok:" + hex(it) } ?: "nil"
        "b64std" -> Base64Std.decodeCanonical(text(f[1]))?.let { "ok:" + hex(it) } ?: "nil"
        "b64urlenc" -> hex(Base64Url.encode(unhex(f[1])))
        "b64stdenc" -> hex(Base64Std.encode(unhex(f[1])))
        "uuid" -> Uuids.parse(text(f[1]))?.let(Uuids::lowercase) ?: "nil"
        "envparse" -> SealedEnvelope.parse(text(f[1])).let { "ok:${hex(it.version)}:${hex(it.nonce)}:${hex(it.sealed)}" }
        "open" -> "ok:" + hex(SnippetCrypto.open(text(f[1]), unhex(f[2]), unhex(f[3])))
        "rec-open" -> "ok:" + hex(SnippetCrypto.open(text(f[1]), context(f[4], f[5], f[6]), keyring(f[2], f[3])))
        "rec-seal" -> "ok:" + hex(SnippetCrypto.seal(unhex(f[1]), context(f[4], f[5], f[6]), keyring(f[2], f[3])))
        "rec-seal-nonce" -> {
            val nonce = unhex(f[7])
            "ok:" + hex(SnippetCrypto.seal(unhex(f[1]), context(f[4], f[5], f[6]), keyring(f[2], f[3]), NonceSource { nonce.copyOf() }))
        }
        "aad-rec" -> hex(SnippetCrypto.additionalData(context(f[1], f[2], f[3])))
        "aad-kw" -> hex(KeyWrap.additionalData(purpose(f[1]), text(f[2])))
        "aad-pw" -> hex(PassphraseKdf.additionalData(text(f[1]), f[2].toLong(), unhex(f[3]), text(f[4])))
        "reckey" -> keyring(f[1], f[2]).let { hex(it.recordKey(UUID.fromString(f[3]))) + ":" + hex(it.contentHashKey()) }
        "chash" -> SnippetCrypto.contentHash(unhex(f[1]), keyring(f[2], f[3]))
        "pad" -> hex(Padding.pad(unhex(f[1])))
        "unpad" -> "ok:" + hex(Padding.unpad(unhex(f[1])))
        "kw-wrap" -> "ok:" + hex(KeyWrap.wrap(unhex(f[1]), unhex(f[2]), purpose(f[3]), text(f[4]), unhex(f[5])))
        "kw-unwrap" -> "ok:" + hex(KeyWrap.unwrap(text(f[1]), unhex(f[2]), purpose(f[3]), text(f[4]), unhex(f[5])))
        "kdf" -> "ok:" + hex(PassphraseKdf.derive(text(f[1]), unhex(f[2]), f[3].toLong()))
        "pw-wrap" -> PassphraseKdf.wrap(unhex(f[1]), text(f[2]), unhex(f[3]), text(f[4]), f[5].toLong()).let {
            "ok:${hex(it.alg)}:${it.iterations}:${hex(it.salt)}:${hex(it.envelope)}"
        }
        "pw-unwrap" -> {
            val wrapped = PassphraseKdf.WrappedKey(text(f[1]), f[2].toLong(), text(f[3]), text(f[4]))
            "ok:" + hex(PassphraseKdf.unwrap(wrapped, text(f[5]), text(f[6])))
        }
        "rk-encode" -> unhex(f[1]).let { "ok:" + hex(RecoveryKey.encode(it)) + ":" + hex(RecoveryKey.formatted(it)) }
        "rk-norm" -> hex(RecoveryKey.normalized(text(f[1])))
        "rk-group" -> hex(RecoveryKey.grouped(text(f[1])))
        "rk-decode" -> "ok:" + hex(RecoveryKey.decode(text(f[1])))
        "detuuid" -> DeterministicUuid.make(UUID.fromString(f[1]), text(f[2])).toString()
        "dbl" -> SwiftDouble.description(Double.fromBits(java.lang.Long.parseUnsignedLong(f[1], 16)))
        // What `PassphraseKdf.normalizedPassword` relies on. Decision D2: Foundation's precomposed form, not java.text NFC.
        "nfc" -> hex(FoundationText.foundationPrecomposed(text(f[1])))
        "utf8str" -> Utf8.decodeStrict(unhex(f[1]))?.let { "ok:" + hex(it) } ?: "nil"
        "plaintext" -> SnippetCrypto.plaintextString(unhex(f[1]))?.let { "ok:" + hex(it) } ?: "nil"
        "validutf8" -> if (CanonicalJson.isValidUtf8(unhex(f[1]))) "1" else "0"
        else -> "err:unknown-kind"
    }

    /** `same` when the port opens what Swift sealed and gets the input back. */
    private fun openSwiftSealed(f: List<String>, verdict: String): String = when (f[0]) {
        "rec-seal" -> {
            val opened = SnippetCrypto.open(text(verdict), context(f[4], f[5], f[6]), keyring(f[2], f[3]))
            if (hex(opened) == f[1]) "same" else "opened to ${hex(opened)}"
        }
        "kw-wrap" -> {
            val opened = KeyWrap.unwrap(text(verdict), unhex(f[2]), purpose(f[3]), text(f[4]), unhex(f[5]))
            if (hex(opened) == f[1]) "same" else "unwrapped to another key"
        }
        "pw-wrap" -> {
            val parts = verdict.split(':')
            val wrapped = PassphraseKdf.WrappedKey(text(parts[0]), parts[1].toLong(), text(parts[2]), text(parts[3]))
            val opened = PassphraseKdf.unwrap(wrapped, text(f[2]), text(f[4]))
            when {
                hex(opened) != f[1] -> "unwrapped to another key"
                wrapped.alg != PassphraseKdf.ALGORITHM -> "alg ${wrapped.alg}"
                wrapped.salt != Base64Url.encode(unhex(f[3])) -> "salt text ${wrapped.salt}"
                wrapped.iterations != f[5].toLong() -> "iterations ${wrapped.iterations}"
                else -> "same"
            }
        }
        else -> error("not a sealing kind")
    }

    // Canonical JSON

    private fun canonical(bytes: ByteArray): String {
        val value = try {
            CanonicalJson.parse(bytes)
        } catch (failure: CanonicalJson.Failure) {
            return canonicalFailure(failure)
        }
        val emitted = try {
            hex(CanonicalJson.encode(value))
        } catch (failure: CanonicalJson.Failure) {
            canonicalFailure(failure)
        }
        return "ok:" + dump(value) + "|" + emitted
    }

    private fun canonicalFailure(failure: CanonicalJson.Failure): String = when (failure) {
        is CanonicalJson.Failure.NonFiniteNumber -> "err:nonFiniteNumber"
        is CanonicalJson.Failure.InvalidUtf8 -> "err:invalidUTF8"
        is CanonicalJson.Failure.UnexpectedEnd -> "err:unexpectedEnd"
        is CanonicalJson.Failure.UnexpectedByte -> "err:unexpectedByte:${failure.offset}"
        is CanonicalJson.Failure.DuplicateKey -> "err:duplicateKey:${hex(failure.key)}"
        is CanonicalJson.Failure.TrailingBytes -> "err:trailingBytes:${failure.offset}"
        is CanonicalJson.Failure.TooDeep -> "err:tooDeep"
    }

    /** A type-tagged spelling of a parsed value: doubles by bit pattern, strings and keys by their bytes. */
    fun dump(value: JsonValue): String = StringBuilder().also { dump(value, it) }.toString()

    private fun dump(value: JsonValue, out: StringBuilder) {
        when (value) {
            JsonValue.Null -> out.append('n')
            is JsonValue.Bool -> out.append(if (value.value) 't' else 'f')
            is JsonValue.Integer -> out.append('i').append(value.value)
            is JsonValue.Real -> out.append('d').append(String.format("%016x", value.value.toRawBits()))
            is JsonValue.Text -> out.append('s').append(hex(value.value))
            is JsonValue.Utf8 -> out.append('s').append(hex(value.bytes))
            is JsonValue.Array -> {
                out.append('[')
                value.elements.forEachIndexed { index, element ->
                    if (index > 0) out.append(',')
                    dump(element, out)
                }
                out.append(']')
            }
            is JsonValue.Object -> {
                out.append('{')
                val sorted = value.members.entries.map { hex(it.key) to it.value }.sortedBy { it.first }
                sorted.forEachIndexed { index, member ->
                    if (index > 0) out.append(',')
                    out.append(member.first).append(':')
                    dump(member.second, out)
                }
                out.append('}')
            }
        }
    }
}
