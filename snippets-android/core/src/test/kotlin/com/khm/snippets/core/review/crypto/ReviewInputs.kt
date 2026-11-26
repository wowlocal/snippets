package com.khm.snippets.core.review.crypto

import com.khm.snippets.core.canonical.SwiftDouble
import com.khm.snippets.core.crypto.AesGcm
import com.khm.snippets.core.crypto.Base64Url
import com.khm.snippets.core.crypto.KeyWrap
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.RecoveryKey
import com.khm.snippets.core.crypto.SealedEnvelope
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.review.crypto.ReviewCrypto.hex
import java.math.BigDecimal
import java.util.UUID

/**
 * Deterministic inputs for the Swift recorder: one TSV line per question, arguments in hex.
 * `scale` 1 is what the checked-in fixtures were recorded from; a larger scale is for a
 * one-off sweep (`ReviewExchangeTest`).
 */
internal class ReviewInputs(private val scale: Int) {

    private fun line(kind: String, vararg arguments: String): String = (listOf(kind) + arguments).joinToString("\t")

    // Text pools

    private val scalarPool: List<IntRange> = listOf(
        0x20..0x7E, 0x20..0x7E, 0x20..0x7E, 0xA0..0xFF, 0x100..0x24F, 0x300..0x36F, 0x370..0x3FF, 0x400..0x4FF,
        0x900..0xDFF, 0xF00..0xFFF, 0x1100..0x11FF, 0x1E00..0x1FFF, 0x2000..0x206F, 0x2100..0x214F, 0x3040..0x30FF,
        0xAC00..0xD7A3, 0xE000..0xE0FF, 0xF900..0xFAFF, 0xFB00..0xFB4F, 0xFE00..0xFE0F, 0xFF00..0xFFEF,
        0x10000..0x100FF, 0x11000..0x111FF, 0x1D100..0x1D1FF, 0x1F300..0x1F6FF, 0x2F800..0x2FA1F, 0xE0100..0xE01EF,
    )

    fun unicodeText(rng: SplitMix64, maximumScalars: Int): String {
        val out = StringBuilder()
        repeat(rng.below(maximumScalars + 1)) {
            val range = rng.pick(scalarPool)
            out.appendCodePoint(range.first + rng.below(range.last - range.first + 1))
        }
        return out.toString()
    }

    private val passphrases = listOf(
        "correct horse battery staple", "Caf\u00E9 public fixture", "Cafe\u0301 public fixture", "\uD83D\uDD11 key \uD83D\uDE00",
        "\u212B", "\u00C5", "A\u030A", "\u1100\u1161\u11A8", "\uAC01", "\uFB01", " leading and trailing ", "a", "\u0000",
        "\u0301", "\uFEFFbom", "pa\u00DFwort", "\u03A9\u2126", "\u3053\u3099", "\uF900", "q\u0307\u0323", "q\u0323\u0307",
        "\u0958", "\uD834\uDD5E", "\u0F73", "\u1E9B\u0323", "tab\there", "line\nbreak", "\u00A0nbsp",
    )

    private val scopes = listOf(
        "sync-v1", "", "kid", "0b9f6a52-0c1e-4c6b-9a55-000000000001", "Caf\u00E9", "Cafe\u0301", "\uD83D\uDD11", "a\u0000b", "\uFEFFscope",
    )

    private fun uuid(rng: SplitMix64): String = when (rng.below(12)) {
        0 -> "00000000-0000-0000-0000-000000000000"
        1 -> "ffffffff-ffff-ffff-ffff-ffffffffffff"
        2 -> "80000000-0000-0000-8000-000000000000"
        else -> UUID(rng.next(), rng.next()).toString()
    }

    private fun plaintextLength(rng: SplitMix64): Int = when (rng.below(10)) {
        0 -> 0
        1 -> rng.pick(listOf(1, 255, 256, 257, 511, 512, 513, 767, 768))
        else -> rng.below(700)
    }

    // Records, wraps and their derived values

    fun crypto(seed: Long): List<String> {
        val rng = SplitMix64(seed)
        val out = ArrayList<String>()

        repeat(120 * scale) {
            val key = rng.bytes(32)
            val salt = rng.bytes(if (rng.chance(4)) 1 + rng.below(64) else 32)
            val scope = if (rng.chance(3)) unicodeText(rng, 12) else rng.pick(scopes)
            val id = uuid(rng)
            val deleted = if (rng.chance(4)) "1" else "0"
            val plaintext = rng.bytes(plaintextLength(rng))
            val context = SnippetCrypto.RecordContext(scope, UUID.fromString(id), deleted == "1")
            val keyring = SnippetCrypto.Keyring(key, salt)

            // Swift seals with its own nonce; the port must open it.
            out += line("rec-seal", hex(plaintext), hex(key), hex(salt), hex(scope), id, deleted)
            // The port seals; Swift must open it to the same bytes.
            val sealed = SnippetCrypto.seal(plaintext, context, keyring)
            check(SnippetCrypto.open(sealed, context, keyring).contentEquals(plaintext)) { "the port cannot reopen its own seal" }
            out += line("rec-open", hex(sealed), hex(key), hex(salt), hex(scope), id, deleted)
            // With the nonce pinned, both must write the same text.
            out += line("rec-seal-nonce", hex(plaintext), hex(key), hex(salt), hex(scope), id, deleted, hex(rng.bytes(12)))
            out += line("aad-rec", hex(scope), id, deleted)
            out += line("reckey", hex(key), hex(salt), id)
            out += line("chash", hex(plaintext), hex(key), hex(salt))

            // The record sealed for one context, opened for a neighbouring one.
            when (rng.below(5)) {
                0 -> out += line("rec-open", hex(sealed), hex(key), hex(salt), hex(scope + "x"), id, deleted)
                1 -> out += line("rec-open", hex(sealed), hex(key), hex(salt), hex(scope), uuid(rng), deleted)
                2 -> out += line("rec-open", hex(sealed), hex(key), hex(salt), hex(scope), id, if (deleted == "1") "0" else "1")
                3 -> out += line("rec-open", hex(sealed), hex(rng.bytes(32)), hex(salt), hex(scope), id, deleted)
                else -> out += line("rec-open", hex(sealed), hex(key), hex(rng.bytes(32)), hex(scope), id, deleted)
            }
        }

        repeat(60 * scale) {
            val libraryKey = rng.bytes(if (rng.chance(12)) rng.pick(listOf(0, 16, 31, 33)) else 32)
            val material = rng.bytes(if (rng.chance(8)) rng.below(16) else 16 + rng.below(49))
            val purpose = if (rng.chance(2)) "recovery" else "cli"
            val kid = if (rng.chance(3)) unicodeText(rng, 10) else rng.pick(scopes)
            val salt = rng.bytes(if (rng.chance(10)) 0 else 1 + rng.below(48))
            out += line("kw-wrap", hex(libraryKey), hex(material), purpose, hex(kid), hex(salt))
            out += line("aad-kw", purpose, hex(kid))

            val kotlinPurpose = KeyWrap.Purpose.entries.first { it.rawValue == purpose }
            val wrapped = try {
                KeyWrap.wrap(libraryKey, material, kotlinPurpose, kid, salt)
            } catch (_: Exception) {
                null
            }
            if (wrapped != null) {
                out += line("kw-unwrap", hex(wrapped), hex(material), purpose, hex(kid), hex(salt))
                val other = if (purpose == "cli") "recovery" else "cli"
                when (rng.below(4)) {
                    0 -> out += line("kw-unwrap", hex(wrapped), hex(material), other, hex(kid), hex(salt))
                    1 -> out += line("kw-unwrap", hex(wrapped), hex(material), purpose, hex(kid + "\u0000"), hex(salt))
                    2 -> out += line("kw-unwrap", hex(wrapped), hex(rng.bytes(material.size)), purpose, hex(kid), hex(salt))
                    else -> out += line("kw-unwrap", hex(wrapped.dropLast(3)), hex(material), purpose, hex(kid), hex(salt))
                }
                // A blob that authenticates but does not hold 32 bytes.
                if (rng.chance(6)) {
                    val wrapping = KeyWrap.wrappingKey(material, kotlinPurpose, salt)
                    val odd = SnippetCrypto.seal(rng.bytes(rng.pick(listOf(0, 16, 31, 33, 64))), wrapping, KeyWrap.additionalData(kotlinPurpose, kid))
                    out += line("kw-unwrap", hex(odd), hex(material), purpose, hex(kid), hex(salt))
                }
            }
        }

        repeat(60 * scale) { round ->
            val key = rng.bytes(if (rng.chance(15)) 31 else 32)
            val passphrase = if (rng.chance(2)) rng.pick(passphrases) else unicodeText(rng, 10)
            val salt = rng.bytes(if (rng.chance(4)) rng.below(40) else 16)
            val kid = if (rng.chance(3)) unicodeText(rng, 10) else rng.pick(scopes)
            val iterations = when {
                round < 2 -> 600_000L
                rng.chance(20) -> rng.pick(listOf(0L, -1L, 20_000_001L, 5_000_000_000L, Long.MIN_VALUE))
                else -> 1L + rng.below(40)
            }
            out += line("pw-wrap", hex(key), hex(passphrase), hex(salt), hex(kid), iterations.toString())
            if (iterations >= 0) out += line("aad-pw", hex(PassphraseKdf.ALGORITHM), iterations.toString(), hex(salt), hex(kid))

            val wrapped = try {
                PassphraseKdf.wrap(key, passphrase, salt, kid, iterations)
            } catch (_: Exception) {
                null
            }
            if (wrapped != null) {
                fun unwrap(alg: String = wrapped.alg, count: Long = wrapped.iterations, saltText: String = wrapped.salt,
                           envelope: String = wrapped.envelope, phrase: String = passphrase, owner: String = kid) =
                    line("pw-unwrap", hex(alg), count.toString(), hex(saltText), hex(envelope), hex(phrase), hex(owner))
                out += unwrap()
                when (rng.below(9)) {
                    0 -> out += unwrap(phrase = passphrase + " ")
                    1 -> out += unwrap(owner = kid + "x")
                    2 -> out += unwrap(count = wrapped.iterations + 1)
                    3 -> out += unwrap(alg = "PBKDF2-HMAC-SHA512")
                    4 -> out += unwrap(saltText = rng.pick(listOf("", "=", "A", wrapped.salt + "=", wrapped.salt + "A")))
                    5 -> out += unwrap(envelope = wrapped.envelope.dropLast(1 + rng.below(4)))
                    6 -> out += unwrap(phrase = "")
                    7 -> out += unwrap(count = rng.pick(listOf(0L, -7L, 20_000_001L)))
                    else -> {
                        // Authenticates, but the payload is not a 32-byte key.
                        val wrapping = PassphraseKdf.derive(passphrase, salt, iterations)
                        val aad = PassphraseKdf.additionalData(PassphraseKdf.ALGORITHM, iterations, salt, kid)
                        out += unwrap(envelope = SnippetCrypto.seal(rng.bytes(rng.pick(listOf(0, 16, 33))), wrapping, aad))
                    }
                }
            }
        }

        repeat(100 * scale) {
            val size = rng.pick(listOf(0, 1, 2, 254, 255, 256, 257, 511, 512, 513)) + if (rng.chance(3)) rng.below(40) else 0
            val body = rng.bytes(size)
            out += line("pad", hex(body))
            // Arbitrary blocks through the strict unpadder: mostly zeros so the marker rule is what decides.
            val block = ByteArray(rng.pick(listOf(0, 1, 255, 256, 257, 512)))
            if (block.isNotEmpty()) {
                repeat(rng.below(3)) { block[rng.below(block.size)] = rng.pick(listOf(0x80, 0x80, 0x01, 0xFF, 0x00)).toByte() }
            }
            out += line("unpad", hex(block))
        }

        repeat(60 * scale) {
            out += line("detuuid", uuid(rng), hex(if (rng.chance(3)) rng.pick(passphrases) else unicodeText(rng, 30)))
        }
        return out
    }

    // Envelope grammar and the open pipeline

    fun envelopes(seed: Long): List<String> {
        val rng = SplitMix64(seed)
        val out = ArrayList<String>()
        val bad = "=+/ .-_A\n\u00E9\u0000"

        repeat(40 * scale) {
            val key = rng.bytes(32)
            val aad = rng.bytes(rng.below(40))
            val plaintext = rng.bytes(rng.below(200))
            val envelope = SnippetCrypto.seal(plaintext, key, aad)
            val parsed = SealedEnvelope.parse(envelope)
            fun both(text: String, withKey: ByteArray = key, withAad: ByteArray = aad) {
                out += line("envparse", hex(text))
                out += line("open", hex(text), hex(withKey), hex(withAad))
            }
            both(envelope)
            both(envelope, withKey = rng.bytes(32))
            both(envelope, withAad = aad + 0.toByte())
            both(envelope, withKey = rng.bytes(rng.pick(listOf(0, 16, 31, 33, 64))))

            repeat(6) {
                val position = rng.below(envelope.length)
                when (rng.below(9)) {
                    0 -> both(envelope.substring(0, position))
                    1 -> both(envelope.substring(0, position) + rng.pick(bad) + envelope.substring(position + 1))
                    2 -> both(envelope.substring(0, position) + rng.pick(bad) + envelope.substring(position))
                    3 -> both(rng.pick(listOf("v2", "", "V1", "v1 ", "v01", "v1\u0000", "\uFEFFv1")) + envelope.substring(2))
                    4 -> both(rng.pick(listOf(envelope + ".AAAA", "." + envelope, envelope + ".", envelope.replace(".", ".."), envelope.replace('.', ','))))
                    5 -> {
                        // The same bytes with other unused low bits in the final symbol, when it has any.
                        val last = envelope.last()
                        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
                        both(envelope.dropLast(1) + alphabet[(alphabet.indexOf(last) + 1 + rng.below(3)) % 64])
                    }
                    6 -> both(SealedEnvelope("v1", rng.bytes(rng.pick(listOf(0, 1, 11, 13, 16))), parsed.sealed).text)
                    7 -> both(SealedEnvelope("v1", parsed.nonce, rng.bytes(rng.pick(listOf(0, 1, 15, 16, 17, 32)))).text)
                    else -> {
                        val sealed = parsed.sealed
                        sealed[rng.below(sealed.size)] = (sealed[rng.below(sealed.size)] + 1).toByte()
                        both(SealedEnvelope("v1", parsed.nonce, sealed).text)
                    }
                }
            }

            // Authentic ciphertext over bytes that are not validly padded.
            val nonce = rng.bytes(12)
            val unpadded = ByteArray(rng.pick(listOf(1, 16, 255, 256, 512)))
            if (rng.chance(2)) unpadded[rng.below(unpadded.size)] = rng.pick(listOf(0x80, 0x01, 0xFF)).toByte()
            both(SealedEnvelope("v1", nonce, AesGcm.seal(key, nonce, unpadded, aad)).text)
        }
        out += line("envparse", hex(""))
        out += line("envparse", hex(".."))
        out += line("envparse", hex("v1..x"))
        out += line("envparse", hex("v1.AA.AA"))
        out += line("envparse", hex("v1.A.AA"))
        out += line("envparse", hex("..."))
        return out
    }

    // base64, UUID text, UTF-8

    fun codecs(seed: Long): List<String> {
        val rng = SplitMix64(seed)
        val out = ArrayList<String>()
        val url = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        val standard = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        val intruders = "=+/-_ \n\r\t.\u0000\u00E9\uFF21\u200B"

        repeat(500 * scale) {
            val alphabet = if (rng.chance(2)) url else standard
            val text = StringBuilder()
            repeat(rng.below(24)) { text.append(rng.pick(alphabet)) }
            if (rng.chance(3)) text.insert(rng.below(text.length + 1), rng.pick(intruders))
            if (rng.chance(3)) repeat(rng.below(4)) { text.append('=') }
            if (rng.chance(12)) text.insert(rng.below(text.length + 1), '=')
            out += line("b64url", hex(text.toString()))
            out += line("b64std", hex(text.toString()))
        }
        repeat(150 * scale) {
            val bytes = rng.bytes(rng.below(40))
            out += line("b64urlenc", hex(bytes))
            out += line("b64stdenc", hex(bytes))
            out += line("b64url", hex(Base64Url.encode(bytes)))
            out += line("b64std", hex(java.util.Base64.getEncoder().encodeToString(bytes)))
            out += line("b64std", hex(java.util.Base64.getEncoder().withoutPadding().encodeToString(bytes)))
            out += line("b64std", hex(java.util.Base64.getMimeEncoder(8, "\r\n".toByteArray()).encodeToString(bytes)))
        }

        val hexDigits = "0123456789abcdefABCDEF"
        repeat(200 * scale) {
            val valid = UUID(rng.next(), rng.next()).toString()
            val text = StringBuilder(if (rng.chance(3)) valid.uppercase() else valid)
            when (rng.below(12)) {
                0 -> text.setLength(rng.below(text.length))
                1 -> text[rng.below(36)] = rng.pick("gG-xz {}\u0000\uFF11\u0661 ")
                2 -> text.insert(rng.below(37), rng.pick(hexDigits + "- "))
                3 -> text.deleteCharAt(rng.below(36))
                4 -> text.insert(0, rng.pick(listOf("{", " ", "urn:uuid:", "\uFEFF", "0x"))).also { if (text[0] == '{') text.append('}') }
                5 -> text.append(rng.pick(listOf(" ", "\n", "\u0000", "\u0000junk", "0", "-")))
                6 -> {
                    val compact = valid.replace("-", "")
                    text.setLength(0)
                    text.append(compact)
                }
                7 -> {
                    // dashes moved: same length, wrong grouping
                    val compact = valid.replace("-", "")
                    text.setLength(0)
                    text.append(compact.substring(0, 7)).append('-').append(compact.substring(7, 12)).append('-')
                        .append(compact.substring(12, 16)).append('-').append(compact.substring(16, 20)).append('-').append(compact.substring(20))
                }
                8 -> {
                    val index = rng.below(36)
                    if (text[index] != '-') text[index] = rng.pick(hexDigits)
                }
                else -> Unit
            }
            out += line("uuid", hex(text.toString()))
        }
        for (short in listOf("1-1-1-1-1", "", "00000000-0000-0000-0000-00000000000g", "00000000_0000_0000_0000_000000000000")) {
            out += line("uuid", hex(short))
        }

        val fragments: List<ByteArray> = listOf(
            byteArrayOf(0x41), byteArrayOf(0x00), byteArrayOf(0x7F), ints(0xC3, 0xA9), ints(0xEF, 0xBB, 0xBF), ints(0xEF, 0xBF, 0xBD),
            ints(0xF0, 0x9F, 0x98, 0x80), ints(0xF4, 0x8F, 0xBF, 0xBF), ints(0xED, 0x9F, 0xBF), ints(0xEE, 0x80, 0x80),
            // ill-formed
            ints(0xC0, 0x80), ints(0xC1, 0xBF), ints(0xE0, 0x80, 0x80), ints(0xED, 0xA0, 0x80), ints(0xED, 0xBF, 0xBF),
            ints(0xF0, 0x80, 0x80, 0x80), ints(0xF4, 0x90, 0x80, 0x80), ints(0xF5, 0x80, 0x80, 0x80), ints(0xF8, 0x88, 0x80, 0x80, 0x80),
            ints(0xFF), ints(0xFE), ints(0x80), ints(0xBF), ints(0xC3), ints(0xE2, 0x82), ints(0xF0, 0x9F, 0x98), ints(0xEF, 0xBB),
        )
        repeat(250 * scale) {
            var bytes = ByteArray(0)
            repeat(rng.below(5)) { bytes += if (rng.chance(4)) rng.pick(fragments.subList(10, fragments.size)) else rng.pick(fragments.subList(0, 10)) }
            out += line("utf8str", hex(bytes))
            out += line("plaintext", hex(bytes))
            out += line("validutf8", hex(bytes))
        }
        return out
    }

    private fun ints(vararg values: Int): ByteArray = ByteArray(values.size) { values[it].toByte() }

    // Recovery keys

    fun recovery(seed: Long): List<String> {
        val rng = SplitMix64(seed)
        val out = ArrayList<String>()
        val separators = listOf(" ", "\t", "\n", "\r", "\u00A0", "-", "\u2010", "\u2011", "\u2012", "\u2013", "\u2014", "\u2212", "_", "\r\n")
        val strangers = listOf(
            "U", "u", "!", ".", ",", "\u2015", "\u202F", "\u2009", "\u3000", "\uFEFF", "\u200B", "\u0301", "\uFE0F", "\u212A", "\u0131", "\u0130",
            "\u017F", "\uFB01", "\u00DF", "\uFF21", "\uFF10", "\u0661", "\uD83D\uDD11", "\u00C5", "\u1100", "\u1161", "\u200D", "\u0000", "\u2028",
            "\u0085", "\u000B", "\u000C", "\u1680", "\u2060", "\u00AD", "\u0149", "\u01F0", "\u0345", "\u1E9E", "\u2160", "\u24B6", "\uD801\uDC28",
        )

        for (size in listOf(0, 1, 15, 17, 32)) out += line("rk-encode", hex(rng.bytes(size)))
        out += line("rk-encode", hex(ByteArray(16)))
        out += line("rk-encode", hex(ByteArray(16) { 0xFF.toByte() }))

        repeat(120 * scale) {
            val bytes = rng.bytes(16)
            val canonical = RecoveryKey.encode(bytes)
            val formatted = RecoveryKey.formatted(bytes)
            out += line("rk-encode", hex(bytes))

            fun ask(text: String) {
                out += line("rk-norm", hex(text))
                out += line("rk-decode", hex(text))
            }
            ask(canonical)
            ask(formatted)
            ask(formatted.lowercase())

            repeat(5) {
                val text = StringBuilder(if (rng.chance(2)) canonical else formatted)
                if (rng.chance(3)) text.replace(0, text.length, text.toString().lowercase())
                repeat(1 + rng.below(3)) {
                    val position = rng.below(text.length + 1)
                    when (rng.below(9)) {
                        0, 1 -> text.insert(position, rng.pick(separators))
                        2 -> text.insert(position, rng.pick(strangers))
                        3 -> if (position < text.length) text.replace(position, position + 1, rng.pick(strangers))
                        4 -> if (position < text.length) text[position] = rng.pick(RecoveryKey.ALPHABET + "ILOUilou")
                        5 -> if (position < text.length) text.deleteCharAt(position)
                        6 -> {
                            // the glyphs Crockford folds
                            val folded = text.toString().replace('1', rng.pick("IiLl1")).replace('0', rng.pick("Oo0"))
                            text.replace(0, text.length, folded)
                        }
                        7 -> if (position + 1 < text.length) {
                            val swap = text[position]
                            text[position] = text[position + 1]
                            text[position + 1] = swap
                        }
                        else -> text.insert(position, rng.pick(RecoveryKey.ALPHABET))
                    }
                }
                ask(text.toString())
            }

            // A 26th symbol with non-zero low bits and a check symbol that matches it.
            val symbols = RecoveryKey.symbolsFromBytes(bytes)
            symbols[25] = symbols[25] or (1 + rng.below(3))
            val nonCanonical = symbols.map { RecoveryKey.ALPHABET[it] }.joinToString("") + RecoveryKey.ALPHABET[RecoveryKey.checkSymbol(symbols)]
            ask(nonCanonical)
            out += line("rk-group", hex(canonical.substring(0, rng.below(canonical.length + 1)) + rng.pick(strangers + separators)))
        }
        for (stranger in strangers + separators) {
            out += line("rk-norm", hex(stranger))
            out += line("rk-norm", hex("7$stranger"))
            out += line("rk-norm", hex("${stranger}7"))
            out += line("rk-decode", hex("0000-0000-0000-0000-0000-0000-00$stranger"))
        }
        return out
    }

    // Passphrase normalisation, through the KDF itself

    fun passphraseKdf(seed: Long): List<String> {
        val rng = SplitMix64(seed)
        val out = ArrayList<String>()
        for (passphrase in passphrases) {
            out += line("kdf", hex(passphrase), hex(rng.bytes(16)), "2")
            out += line("nfc", hex(passphrase))
        }
        repeat(400 * scale) {
            val passphrase = unicodeText(rng, 8)
            out += line("kdf", hex(passphrase), hex(rng.bytes(if (rng.chance(10)) rng.below(4) else 16)), (1 + rng.below(3)).toString())
            out += line("nfc", hex(passphrase))
        }
        for (iterations in listOf("0", "-1", "20000000", "20000001", "9223372036854775807")) {
            if (iterations != "20000000") out += line("kdf", hex("public fixture"), hex(rng.bytes(16)), iterations)
        }
        out += line("kdf", hex(""), hex(""), "0")
        out += line("kdf", hex("x"), hex(""), "0")
        out += line("kdf", hex("public fixture"), hex(rng.bytes(16)), "600000")
        return out
    }

    /** Every Unicode scalar on its own, after `a`, and before U+0301. Full sweeps only: 3.3 million lines. */
    fun everyScalar(): Sequence<String> = sequence {
        for (scalar in 0..0x10FFFF) {
            if (scalar in 0xD800..0xDFFF) continue
            val single = String(Character.toChars(scalar))
            yield(line("nfc", hex(single)))
            yield(line("nfc", hex("a$single")))
            yield(line("nfc", hex("$single\u0301")))
            yield(line("rk-norm", hex(single)))
        }
    }

    // Doubles

    fun doubles(seed: Long): List<String> {
        val rng = SplitMix64(seed)
        val bits = LinkedHashSet<Long>()
        fun add(value: Double) {
            if (value.isFinite()) {
                bits += value.toRawBits()
                bits += (-value).toRawBits()
            }
        }
        fun neighbourhood(value: Double, reach: Int) {
            var up = value
            var down = value
            add(value)
            repeat(reach) {
                up = Math.nextUp(up)
                down = Math.nextDown(down)
                add(up)
                add(down)
            }
        }
        add(0.0)
        // Every power of two with its neighbours, subnormals included.
        for (exponent in -1074..1023) neighbourhood(Math.scalb(1.0, exponent), 1)
        // Every power of ten, the layout thresholds and the classic hard cases.
        for (exponent in -323..308) neighbourhood("1e$exponent".toDouble(), 2)
        for (value in listOf(1e-5, 1e-4, 9.999e-5, 0.001, 9007199254740992.0, 9007199254740993.0, 1e15, 1e16, 1e17, 1e21, 1e22, 1e23, 5e-324,
            2.2250738585072014e-308, 2.225073858507201e-308, 1.7976931348623157e308, 4.35, 0.1, 0.3, 2.0 / 3, 5e-324 * 3, 9.5, 1.5, 123456.7)) {
            neighbourhood(value, 40 * scale)
        }
        for (subnormal in 1L..(200L * scale)) add(Double.fromBits(subnormal))
        repeat(300 * scale) { add(Double.fromBits(rng.next() and 0x000F_FFFF_FFFF_FFFFL)) }   // random subnormals
        for (integer in 0..(300 * scale)) add(integer.toDouble())
        repeat(1500 * scale) { add(nextReviewDouble(rng)) }
        // Short decimals: d.ddd × 10^e for every exponent.
        repeat(1500 * scale) { add("${1 + rng.below(9999)}e${rng.below(632) - 324}".toDouble()) }
        // Timestamps as the model stores them.
        repeat(500 * scale) { add((rng.below(1_000_000_000) + 500_000_000) + rng.below(1000) / 1000.0) }
        return bits.map { line("dbl", String.format("%016x", it)) }
    }

    // Canonical JSON

    private sealed interface Node
    private object NullNode : Node
    private class BoolNode(val value: Boolean) : Node
    private class NumberNode(val token: String) : Node
    private class StringNode(val text: String) : Node
    private class ArrayNode(val items: List<Node>) : Node
    private class ObjectNode(val members: List<Pair<String, Node>>) : Node

    private val stringAtoms = listOf(
        "a", "b", "Z", " ", "\"", "\\", "/", "\b", "\u000C", "\n", "\r", "\t", "\u0000", "\u0001", "\u001F", "\u007F", "\u0080", "\u00E9",
        "e\u0301", "\u2028", "\u2029", "\uFEFF", "\uFFFD", "\uFFFF", "\uE000", "\uD7FF", "\uD800\uDC00", "\uD83D\uDE00", "\uDBFF\uDFFF",
        "\u1100\u1161", "\uAC00", "\u212A", "K", "\u00C5", "\u212B", "A\u030A", "0", "true", "null", "{", "}", "[", "]", ",", ":",
    )

    private val keyPool = listOf(
        "", "a", "b", "aa", "A", "Z", "id", "x", "hash", "\u00E9", "e\u0301", "\uFEFFa", "\uFEFF", "a\u0000", "\u0000", "\uE000", "\uFFFF",
        "\uD800\uDC00", "\uDBFF\uDFFF", "\uD83D\uDE00", "\u00E4", "k1", "k2", "k10", "K", "\u212A", "\u00C5", "\u212B", "A\u030A",
        "\uAC00", "\u1100\u1161", "\u03A9", "\u2126", "\uFB01", "fi", "a\"b", "a\\b", "a/b", "\n", "\u007F",
    )

    private fun randomString(rng: SplitMix64): String {
        val out = StringBuilder()
        repeat(rng.below(6)) { out.append(rng.pick(stringAtoms)) }
        return out.toString()
    }

    private fun numberToken(rng: SplitMix64): String = when (rng.below(16)) {
        0 -> rng.next().toString()
        1 -> rng.pick(listOf("0", "-0", "1", "-1", "9223372036854775807", "-9223372036854775808", "9223372036854775808",
            "-9223372036854775809", "18446744073709551616", "123456789012345678901234567890", "9007199254740993"))
        2 -> SwiftDouble.description(nextReviewDouble(rng))
        3 -> nextReviewDouble(rng).toString()                                  // Java's spelling: `1.0E10`
        4 -> rng.pick(listOf("0.0", "-0.0", "0e0", "-0e0", "0E+0", "0.0e-0", "1E5", "1e+5", "1e-5", "1.0", "1.50", "100e-2", "0.1e1",
            "1e400", "-1e400", "1e-400", "-1e-400", "1e99999999999999999999", "1e-99999999999999999999", "0e99999999999999999999",
            "4.9e-324", "2.4703282292062328e-324", "2.4703282292062327e-324", "1.7976931348623157e308", "1.7976931348623158e308",
            "1.7976931348623159e308", "2.2250738585072011e-308", "2.2250738585072012e-308", "0.1", "0.30000000000000004"))
        5 -> {
            // exactly halfway between two adjacent doubles, and a hair to either side
            val value = Math.abs(nextReviewDouble(rng))
            val midpoint = BigDecimal(value).add(BigDecimal(Math.nextUp(value))).divide(BigDecimal(2))
            val text = midpoint.toPlainString()
            when (rng.below(3)) {
                0 -> text
                1 -> if (text.contains('.')) text + "1" else "$text.0000000001"
                else -> BigDecimal(text).subtract(midpoint.ulp()).toPlainString().let { if (it.contains('.') || it.contains('E')) it else "$it.0" }
            }
        }
        6 -> {
            val digits = StringBuilder()
            repeat(1 + rng.below(30)) { digits.append(rng.pick("0123456789")) }
            val whole = digits.toString().trimStart('0').ifEmpty { "0" }
            val fraction = StringBuilder()
            repeat(1 + rng.below(30)) { fraction.append(rng.pick("0123456789")) }
            "$whole.$fraction" + if (rng.chance(2)) "${rng.pick("eE")}${rng.pick(listOf("", "+", "-"))}${rng.below(400)}" else ""
        }
        7 -> {
            // very long digit strings
            val digits = StringBuilder()
            repeat(300 + rng.below(700)) { digits.append(rng.pick("0123456789")) }
            val text = digits.toString().trimStart('0').ifEmpty { "0" }
            when (rng.below(3)) {
                0 -> text
                1 -> "0.$digits"
                else -> "$text.${digits}e-${rng.below(1500)}"
            }
        }
        8 -> rng.pick(listOf("+1", "01", "-01", ".5", "1.", "1e", "1e+", "--1", "0x10", "NaN", "Infinity", "-Infinity", "-", "1.e3", "\uFF11",
            "1_000", "1,5", "1d", "1f", "1.0f", "0x1p3", "1e5L", " 1", "1 ", "1e1.5", "00", "-00.0", "1E", "- 1", "1.0e+", "\u0661", "1L"))
        else -> (rng.below(2000) - 1000).toString()
    }

    private fun randomNode(rng: SplitMix64, depth: Int): Node = when (if (depth <= 0) rng.below(5) else rng.below(8)) {
        0 -> NullNode
        1 -> BoolNode(rng.chance(2))
        2, 3 -> NumberNode(numberToken(rng))
        4 -> StringNode(randomString(rng))
        5, 6 -> ArrayNode(List(rng.below(5)) { randomNode(rng, depth - 1) })
        else -> {
            val members = ArrayList<Pair<String, Node>>()
            repeat(rng.below(6)) { members += (if (rng.chance(4)) randomString(rng) else rng.pick(keyPool)) to randomNode(rng, depth - 1) }
            ObjectNode(members)
        }
    }

    private fun whitespace(rng: SplitMix64, out: StringBuilder, noisy: Boolean) {
        if (noisy && rng.chance(4)) repeat(1 + rng.below(2)) { out.append(rng.pick(" \t\n\r")) }
    }

    private fun writeString(text: String, rng: SplitMix64, out: StringBuilder, noisy: Boolean) {
        out.append('"')
        var index = 0
        while (index < text.length) {
            val scalar = text.codePointAt(index)
            index += Character.charCount(scalar)
            val escape = noisy && rng.chance(5)
            when {
                scalar == '"'.code -> out.append("\\\"")
                scalar == '\\'.code -> out.append("\\\\")
                scalar == '/'.code && escape -> out.append("\\/")
                scalar < 0x20 && !escape -> when (scalar) {
                    0x08 -> out.append("\\b")
                    0x09 -> out.append("\\t")
                    0x0A -> out.append("\\n")
                    0x0C -> out.append("\\f")
                    0x0D -> out.append("\\r")
                    else -> out.append(String.format("\\u%04x", scalar))
                }
                scalar < 0x20 || escape -> for (unit in Character.toChars(scalar)) {
                    out.append(String.format(if (rng.chance(2)) "\\u%04x" else "\\u%04X", unit.code))
                }
                else -> out.appendCodePoint(scalar)
            }
        }
        out.append('"')
    }

    private fun write(node: Node, rng: SplitMix64, out: StringBuilder, noisy: Boolean) {
        whitespace(rng, out, noisy)
        when (node) {
            NullNode -> out.append("null")
            is BoolNode -> out.append(node.value)
            is NumberNode -> out.append(node.token)
            is StringNode -> writeString(node.text, rng, out, noisy)
            is ArrayNode -> {
                out.append('[')
                node.items.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    write(item, rng, out, noisy)
                }
                whitespace(rng, out, noisy)
                out.append(']')
            }
            is ObjectNode -> {
                out.append('{')
                node.members.forEachIndexed { index, member ->
                    if (index > 0) out.append(',')
                    whitespace(rng, out, noisy)
                    writeString(member.first, rng, out, noisy)
                    whitespace(rng, out, noisy)
                    out.append(':')
                    write(member.second, rng, out, noisy)
                }
                whitespace(rng, out, noisy)
                out.append('}')
            }
        }
        whitespace(rng, out, noisy)
    }

    private val mutationBytes = "\"{}[],:\\ \n0123456789eE.-+tfnu".toByteArray(Charsets.US_ASCII) +
        ints(0x80, 0xC0, 0xEF, 0xBB, 0xBF, 0x00, 0xFF, 0xED, 0xA0, 0xF4, 0x90, 0x1F, 0x7F)

    private fun mutate(bytes: ByteArray, rng: SplitMix64): ByteArray {
        if (bytes.isEmpty()) return byteArrayOf(rng.pick(mutationBytes.asList()))
        val position = rng.below(bytes.size)
        return when (rng.below(6)) {
            0 -> bytes.copyOfRange(0, position)
            1 -> bytes.copyOfRange(0, position) + bytes.copyOfRange(position + 1, bytes.size)
            2 -> bytes.copyOfRange(0, position) + rng.pick(mutationBytes.asList()) + bytes.copyOfRange(position, bytes.size)
            3 -> bytes.copyOf().also { it[position] = rng.pick(mutationBytes.asList()) }
            4 -> {
                val end = minOf(bytes.size, position + 1 + rng.below(8))
                bytes.copyOfRange(0, end) + bytes.copyOfRange(position, bytes.size)
            }
            else -> bytes + rng.pick(mutationBytes.asList())
        }
    }

    fun canonical(seed: Long): List<String> {
        val rng = SplitMix64(seed)
        val out = LinkedHashSet<String>()
        fun ask(bytes: ByteArray) {
            out += line("canon", hex(bytes))
        }
        fun ask(text: String) = ask(text.toByteArray(Charsets.UTF_8))

        repeat(700 * scale) {
            val node = randomNode(rng, 1 + rng.below(5))
            val compact = StringBuilder().also { write(node, rng, it, noisy = false) }.toString().toByteArray(Charsets.UTF_8)
            val noisy = StringBuilder().also { write(node, rng, it, noisy = true) }.toString().toByteArray(Charsets.UTF_8)
            ask(compact)
            ask(noisy)
            ask(mutate(noisy, rng))
            ask(mutate(mutate(compact, rng), rng))
        }
        // Every number spelling on its own, where the token is the whole document.
        repeat(1200 * scale) { ask(numberToken(rng)) }

        // Nesting around the limit, in every shape.
        for (depth in listOf(1, 2, 31, 32, 33, 34, 35, 64)) {
            ask("[".repeat(depth) + "]".repeat(depth))
            ask("[".repeat(depth) + "1" + "]".repeat(depth))
            ask("{\"a\":".repeat(depth) + "1" + "}".repeat(depth))
            ask("{\"a\":".repeat(depth) + "{}" + "}".repeat(depth))
            ask("{\"a\":".repeat(depth) + "[]" + "}".repeat(depth))
            ask("[{\"a\":".repeat(depth / 2) + "null" + "}]".repeat(depth / 2))
            ask(" [".repeat(depth) + " ]".repeat(depth))
            ask("[".repeat(depth))
            ask("{\"a\":".repeat(depth))
            ask("[".repeat(depth) + "\"" + "]".repeat(depth))
        }
        ask("[".repeat(100_000))
        ask("{\"a\":".repeat(20_000))
        ask("[".repeat(33) + "x")

        // Strings and escapes the generator cannot reach.
        for (text in listOf(
            "\"\\ud800\"", "\"\\udc00\"", "\"\\ud800\\u0041\"", "\"\\ud800\\ud800\"", "\"\\ud83d\\ude00\"", "\"\\uD83D\\uDE00\"",
            "\"\\ud800x\"", "\"\\ud800\\\"", "\"\\ud800\\u\"", "\"\\ud800\\udc0\"", "\"\\u12\"", "\"\\u12g4\"", "\"\\x41\"", "\"\\a\"", "\"\\'\"",
            "\"\\u0000\"", "\"\\uFEFF\"", "\"\\ufeffa\"", "\"\\", "\"", "\"abc", "\"\\u", "'a'", "\"a\"b", "\"\\uDBFF\\uDFFF\"", "\"\\ud7ff\\ue000\"",
            "{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}", "{\"\u00E9\":1,\"e\u0301\":2}", "{\"e\u0301\":1,\"\\u00e9\":2}", "{\"K\":1,\"\u212A\":2}",
            "{\"\u00C5\":1,\"\u212B\":2,\"A\u030A\":3}", "{\"\uAC00\":1,\"\u1100\u1161\":2}", "{\"\u03A9\":1,\"\u2126\":2}", "{\"\uFB01\":1,\"fi\":2}",
            "{\"\uFEFFa\":1}", "{\"\uFEFFa\":1,\"a\":2}", "{\"a\":1,\"\uFEFFa\":2}", "{\"\uFEFF\":1,\"\":2}", "{\"\uFEFF\uFEFFa\":1,\"\uFEFFa\":2}",
            "{\"\\ufeffa\":1,\"a\":2}", "{\"a\uFEFF\":1,\"a\":2}", "{\"a\\u0000\":1,\"a\":2}", "{\"\\u0000\":1,\"\":2}",
            "{\"\uE000\":1,\"\uD800\uDC00\":2,\"\uFFFF\":3,\"\uDBFF\uDFFF\":4,\"\u00E9\":5,\"z\":6,\"Z\":7,\"\":8}",
            "{\"q\u0307\u0323\":1,\"q\u0323\u0307\":2}", "{\"\u1E0B\u0323\":1,\"\u1E0D\u0307\":2}", "{\"\u0958\":1,\"\u0915\u093C\":2}",
            "{\"\uF900\":1,\"\u8C48\":2}", "{\"\u2000\":1,\"\u2002\":2}", "{\"\u037E\":1,\";\":2}", "{\"\u1FEF\":1,\"`\":2}",
            "{\"\uD834\uDD5E\":1,\"\uD834\uDD57\uD834\uDD65\":2}", "{\"\u0344\":1,\"\u0308\u0301\":2}",
            "{}", "[]", "{ }", "[ ]", "{,}", "[,]", "[1,]", "{\"a\":1,}", "{\"a\"}", "{\"a\":}", "{a:1}", "{1:1}", "{\"a\" 1}", "[1 2]", "[1,,2]",
            "true", "false", "null", "tru", "nul", "fals", "truee", "nulll", "True", "t", "n", "f", "true false", "1 2", "", " ", "\n", "\u00A0" + "1",
            "\uFEFF1", "\uFEFF{}", "1\uFEFF", "[]\u0000", "\u0000", "// c\n1", "/* c */1", "[1]//", "1\u000B", "1\u000C", "\u000C1", "\u2028" + "1",
        )) ask(text)
        // Ill-formed UTF-8 inside a string and as a key.
        for (raw in listOf(ints(0xC0, 0x80), ints(0xED, 0xA0, 0x80), ints(0xF4, 0x90, 0x80, 0x80), ints(0xFF), ints(0xC3), ints(0xE2, 0x82),
            ints(0xEF, 0xBB, 0xBF), ints(0xF0, 0x9F, 0x98, 0x80), ints(0x80), ints(0xF8, 0x88, 0x80, 0x80, 0x80), ints(0xEF, 0xBF, 0xBE))) {
            ask(byteArrayOf('"'.code.toByte()) + raw + byteArrayOf('"'.code.toByte()))
            ask("{\"".toByteArray() + raw + "\":1}".toByteArray())
            ask("{\"".toByteArray() + raw + "\":1,\"\":2}".toByteArray())
            ask("[\"a".toByteArray() + raw + "\"]".toByteArray())
        }
        return out.toList()
    }

    companion object {
        /** Checked in under `fixtures/review-crypto/`, one file per group so a failure names its area. */
        val groups: Map<String, (ReviewInputs) -> List<String>> = linkedMapOf(
            "crypto" to { it.crypto(0x5EED01) },
            "envelopes" to { it.envelopes(0x5EED02) },
            "codecs" to { it.codecs(0x5EED03) },
            "recovery" to { it.recovery(0x5EED04) },
            "passphrase" to { it.passphraseKdf(0x5EED05) },
            "doubles" to { it.doubles(0x5EED06) },
            "canonical" to { it.canonical(0x5EED07) },
        )
    }
}
