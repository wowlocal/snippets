package com.khm.snippets.core.git

import java.util.Locale
import okhttp3.HttpUrl

/**
 * Host names as Foundation reads them, so that every platform connects to the same
 * host and derives the same `canonicalIdentity` from one address.
 *
 * Foundation converts an international name with UTS #46 (non-transitional, with
 * the joiner and bidi checks, without the STD3 and hyphen rules). OkHttp's own URL
 * parser implements the same mapping, normalization and Punycode steps, so it does
 * the conversion here; the validity checks it leaves out are applied on top. A name
 * that cannot be shown to convert identically is refused: connecting to a different
 * host than an iPhone would, with the same token, is the one outcome to exclude.
 */
internal object GitHostNames {
    /** What Foundation accepts in an ASCII registered name besides letters and digits. */
    private const val ASCII_PUNCTUATION = "-._!$&'()*+,;=~"

    private const val ACE_PREFIX = "xn--"

    private fun isHostAscii(character: Char): Boolean =
        character in 'a'..'z' || character in 'A'..'Z' || character in '0'..'9' || ASCII_PUNCTUATION.indexOf(character) >= 0

    private fun String.isAscii(): Boolean = all { it.code < 0x80 }

    /**
     * The lowercase ASCII form of an HTTPS host (international labels as `xn--`),
     * or null when the host is refused. `host` has no brackets and no port.
     *
     * Foundation leaves a plain ASCII name alone: any label lengths, hyphens and
     * dots. A name with a non-ASCII character or an `xn--` label goes through the
     * IDNA conversion as a whole, and there the usual label rules do apply: no empty
     * label (one trailing dot aside), at most 63 bytes a label and 253 in all, no
     * hyphen at either end of a label or in its third and fourth place.
     */
    fun canonical(host: String): String? {
        if (host.isEmpty()) return null
        // Every ASCII character must be one a host may hold; `%` is not one of them.
        if (host.any { it.code < 0x80 && it != '.' && !isHostAscii(it) }) return null
        // IDNA reads these three as the label separator too.
        val pieces = host.split('.', '\u3002', '\uff0e', '\uff61')
        val international = !host.isAscii() || pieces.any { it.startsWith(ACE_PREFIX, ignoreCase = true) }
        if (!international) return host.lowercase(Locale.ROOT)

        val labels = ArrayList<String>(pieces.size)
        val unicodeLabels = ArrayList<String>(pieces.size)
        for ((index, piece) in pieces.withIndex()) {
            if (piece.isEmpty()) {
                // One trailing dot names the root and is not a label.
                if (index == pieces.lastIndex && index > 0) continue
                return null
            }
            val label = convert(piece) ?: return null
            val unicode = label.unicode
            if (label.ascii.length > 63 || unicode.startsWith("-") || unicode.endsWith("-")) return null
            if (unicode.length >= 4 && unicode[2] == '-' && unicode[3] == '-') return null
            labels.add(label.ascii)
            unicodeLabels.add(unicode)
        }
        if (labels.isEmpty() || !satisfiesBidiRule(unicodeLabels)) return null
        val name = labels.joinToString(".")
        if (name.length > 253) return null
        return if (pieces.last().isEmpty()) "$name." else name
    }

    private class Label(val ascii: String, val unicode: String)

    private fun convert(piece: String): Label? {
        if (piece.isAscii()) {
            val lower = piece.lowercase(Locale.ROOT)
            if (!lower.startsWith(ACE_PREFIX)) return Label(lower, lower)
            // An `xn--` label must be valid, and already be what it converts to.
            if (toAscii(lower) != lower) return null
            return Label(lower, unicodeLabel(lower) ?: return null)
        }
        val mapped = mapped(piece) ?: return null
        // Mapped away entirely, to several labels, or to something that only now
        // spells an `xn--` label: not a name anyone meant, and not worth a guess.
        if (mapped.isEmpty() || mapped.contains('.') || mapped.startsWith(ACE_PREFIX)) return null
        if (mapped.isAscii()) return if (mapped.all(::isHostAscii)) Label(mapped, mapped) else null
        val ascii = toAscii(piece) ?: return null
        if (!ascii.startsWith(ACE_PREFIX)) return null
        val unicode = unicodeLabel(ascii) ?: return null
        return if (unicode == mapped) Label(ascii, unicode) else null
    }

    /**
     * The label after UTS #46 mapping and normalization, before any Punycode step.
     * OkHttp only hands out the final ASCII form, so the label is converted behind a
     * digit, which neither composes with what follows nor lets the label be taken
     * for an `xn--` one, and the digit is removed again.
     */
    private fun mapped(piece: String): String? {
        val converted = toAscii("0$piece") ?: return null
        val unicode = if (converted.startsWith(ACE_PREFIX)) Punycode.decode(converted.substring(ACE_PREFIX.length)) ?: return null else converted
        return if (unicode.startsWith("0")) unicode.substring(1) else null
    }

    /**
     * The host of an `ssh://` address as `URLComponents.host` reports it: the Unicode
     * form, of which Swift then accepts only ASCII. So a name that needs `xn--` is
     * refused in either spelling, while a compatibility form of an ASCII name (a
     * full-width letter) becomes that name, in lowercase.
     */
    fun sshUrlHost(host: String): String? {
        if (host.isAscii()) {
            return host.takeIf { text -> text.split('.').none { it.startsWith(ACE_PREFIX, ignoreCase = true) } }
        }
        return canonical(host)?.takeIf { text -> text.split('.').none { it.startsWith(ACE_PREFIX) } }
    }

    /** OkHttp's UTS #46 processing of one label: mapping, normalization, Punycode. */
    private fun toAscii(piece: String): String? = try {
        HttpUrl.Builder().scheme("https").host(piece).build().host
    } catch (_: Exception) {
        // Not a host OkHttp can convert (it throws `IllegalArgumentException`).
        null
    }

    /**
     * The Unicode form of a valid `xn--` label, or null. These are the UTS #46
     * validity criteria OkHttp does not apply.
     */
    private fun unicodeLabel(label: String): String? {
        val unicode = Punycode.decode(label.substring(ACE_PREFIX.length)) ?: return null
        if (unicode.isAscii()) return null
        var index = 0
        while (index < unicode.length) {
            val scalar = unicode.codePointAt(index)
            // A character this runtime's Unicode tables do not know cannot be checked.
            if (Character.getType(scalar) == Character.UNASSIGNED.toInt() ||
                Character.getDirectionality(scalar) == Character.DIRECTIONALITY_UNDEFINED
            ) {
                return null
            }
            // The joiners are valid only in contexts that need tables this code does
            // not have (Foundation refuses them between Latin letters, for example).
            if (scalar == 0x200c || scalar == 0x200d) return null
            index += Character.charCount(scalar)
        }
        when (Character.getType(unicode.codePointAt(0)).toByte()) {
            Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK -> return null
        }
        // Every character is valid, mapped and normalized exactly when the label
        // converts back to itself.
        if (toAscii(unicode) != label) return null
        return unicode
    }

    private const val L = Character.DIRECTIONALITY_LEFT_TO_RIGHT
    private const val R = Character.DIRECTIONALITY_RIGHT_TO_LEFT
    private const val AL = Character.DIRECTIONALITY_RIGHT_TO_LEFT_ARABIC
    private const val EN = Character.DIRECTIONALITY_EUROPEAN_NUMBER
    private const val ES = Character.DIRECTIONALITY_EUROPEAN_NUMBER_SEPARATOR
    private const val ET = Character.DIRECTIONALITY_EUROPEAN_NUMBER_TERMINATOR
    private const val AN = Character.DIRECTIONALITY_ARABIC_NUMBER
    private const val CS = Character.DIRECTIONALITY_COMMON_NUMBER_SEPARATOR
    private const val NSM = Character.DIRECTIONALITY_NONSPACING_MARK
    private const val BN = Character.DIRECTIONALITY_BOUNDARY_NEUTRAL
    private const val ON = Character.DIRECTIONALITY_OTHER_NEUTRALS

    private fun directions(label: String): List<Byte> {
        val result = ArrayList<Byte>(label.length)
        var index = 0
        while (index < label.length) {
            val scalar = label.codePointAt(index)
            result.add(Character.getDirectionality(scalar))
            index += Character.charCount(scalar)
        }
        return result
    }

    /** The Bidi rule of RFC 5893, section 2, applied when any label holds a right-to-left character. */
    private fun satisfiesBidiRule(labels: List<String>): Boolean {
        val all = labels.map(::directions)
        if (all.none { label -> label.any { it == R || it == AL || it == AN } }) return true
        for (label in all) {
            if (label.isEmpty()) continue
            val first = label.first()
            val last = label.lastOrNull { it != NSM } ?: return false
            // Allowed in a label of either direction.
            fun neutral(direction: Byte) =
                direction == EN || direction == ES || direction == CS || direction == ET || direction == ON || direction == BN || direction == NSM
            if (first == R || first == AL) {
                if (!label.all { it == R || it == AL || it == AN || neutral(it) }) return false
                if (last != R && last != AL && last != EN && last != AN) return false
                if (label.contains(EN) && label.contains(AN)) return false
            } else if (first == L) {
                if (!label.all { it == L || neutral(it) }) return false
                if (last != L && last != EN) return false
            } else {
                return false
            }
        }
        return true
    }

    /** RFC 3492, decoding only. */
    private object Punycode {
        private const val BASE = 36
        private const val T_MIN = 1
        private const val T_MAX = 26
        private const val SKEW = 38
        private const val DAMP = 700
        private const val INITIAL_BIAS = 72
        private const val INITIAL_N = 0x80

        /** The Unicode label for what follows `xn--`, or null when it is not valid Punycode. */
        fun decode(input: String): String? {
            val output = ArrayList<Int>()
            val delimiter = input.lastIndexOf('-')
            for (index in 0 until maxOf(delimiter, 0)) {
                if (input[index].code >= 0x80) return null
                output.add(input[index].code)
            }
            var position = if (delimiter >= 0) delimiter + 1 else 0
            var n = INITIAL_N
            var i = 0
            var bias = INITIAL_BIAS
            while (position < input.length) {
                val oldI = i
                var weight = 1
                var k = BASE
                while (true) {
                    if (position >= input.length) return null
                    val digit = when (val character = input[position++]) {
                        in 'a'..'z' -> character - 'a'
                        in 'A'..'Z' -> character - 'A'
                        in '0'..'9' -> character - '0' + 26
                        else -> return null
                    }
                    if (digit > (Int.MAX_VALUE - i) / weight) return null
                    i += digit * weight
                    val threshold = when {
                        k <= bias -> T_MIN
                        k >= bias + T_MAX -> T_MAX
                        else -> k - bias
                    }
                    if (digit < threshold) break
                    if (weight > Int.MAX_VALUE / (BASE - threshold)) return null
                    weight *= BASE - threshold
                    k += BASE
                }
                bias = adapt(i - oldI, output.size + 1, oldI == 0)
                if (i / (output.size + 1) > Int.MAX_VALUE - n) return null
                n += i / (output.size + 1)
                i %= output.size + 1
                if (n > 0x10ffff || n in 0xd800..0xdfff) return null
                output.add(i, n)
                i += 1
            }
            val text = StringBuilder()
            for (scalar in output) text.appendCodePoint(scalar)
            return text.toString()
        }

        private fun adapt(delta: Int, count: Int, first: Boolean): Int {
            var value = if (first) delta / DAMP else delta / 2
            value += value / count
            var k = 0
            while (value > (BASE - T_MIN) * T_MAX / 2) {
                value /= BASE - T_MIN
                k += BASE
            }
            return k + (BASE - T_MIN + 1) * value / (value + SKEW)
        }
    }
}
