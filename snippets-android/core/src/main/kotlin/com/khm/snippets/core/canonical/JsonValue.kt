package com.khm.snippets.core.canonical

import com.khm.snippets.core.crypto.Utf8 as Utf8Codec
import java.util.Collections

/**
 * A lossless JSON value: what [CanonicalJson] emits and parses, and what a passthrough
 * bag of unknown fields is made of.
 *
 * Swift has two models, `CanonicalJSON.Value` (hand-emitted, hashed) and the `Codable`
 * `JSONValue` (vault passthrough). They hold the same cases, apart from the byte-string
 * one, and the split exists there only because of `Codable`; this one type serves both.
 *
 * - [Integer] and [Real] stay distinct: `600000` never becomes `600000.0`, and `1.0`
 *   never becomes `1`.
 * - [Text] and [Utf8] are the same JSON string and compare equal. [Utf8] exists so a
 *   secure snippet's body never has to become a `String`, which cannot be wiped.
 * - [Object] keeps keys exactly as given. The emitter sorts them; nothing normalises them.
 *
 * Values are immutable, with one stated exception: [Utf8] shares its array.
 *
 * Equality differs from Swift in one corner. A Swift dictionary treats canonically
 * equivalent keys (`é` as U+00E9 or as `e` + U+0301) as one key; a Kotlin map does not.
 * The parser and the emitter both refuse an object that holds two such keys, so the
 * difference cannot reach canonical bytes.
 */
sealed class JsonValue {

    object Null : JsonValue() {
        override fun toString(): String = "null"
    }

    class Bool(val value: Boolean) : JsonValue() {
        override fun equals(other: Any?): Boolean = other is Bool && value == other.value
        override fun hashCode(): Int = value.hashCode()
        override fun toString(): String = value.toString()
    }

    /** Swift `.int` / `.integer`: an `Int64`. */
    class Integer(val value: Long) : JsonValue() {
        override fun equals(other: Any?): Boolean = other is Integer && value == other.value
        override fun hashCode(): Int = value.hashCode()
        override fun toString(): String = value.toString()
    }

    /** Swift `.double`. Never equal to an [Integer], even for the same number. */
    class Real(val value: Double) : JsonValue() {
        // IEEE comparison as in Swift, so 0.0 == -0.0. NaN equals itself here, which Swift's
        // does not: `equals` must be reflexive on the JVM. No parsed value is ever NaN.
        override fun equals(other: Any?): Boolean =
            other is Real && (value == other.value || (value.isNaN() && other.value.isNaN()))

        override fun hashCode(): Int = if (value == 0.0) 0 else value.hashCode()
        override fun toString(): String = value.toString()
    }

    /** A JSON string held as text. For plaintext metadata only; a snippet body belongs in [Utf8]. */
    class Text(val value: String) : JsonValue() {
        override fun equals(other: Any?): Boolean = when (other) {
            is Text -> value == other.value
            is Utf8 -> Utf8Codec.encodeStrict(value)?.contentEquals(other.bytes) ?: false
            else -> false
        }

        override fun hashCode(): Int = Utf8Codec.encodeStrict(value)?.contentHashCode() ?: value.hashCode()
        override fun toString(): String = "Text(${value.length} chars)"
    }

    /**
     * A JSON string held as its UTF-8 bytes; every string the parser returns is one.
     *
     * The array is **not** copied: the value takes it over, and [bytes] returns that same
     * array. That keeps a secret body in one place that [wipe] can zero. Do not modify it
     * otherwise.
     */
    class Utf8(val bytes: ByteArray) : JsonValue() {

        /** Zeroes the bytes. The value is unusable afterwards. */
        fun wipe() {
            bytes.fill(0)
        }

        override fun equals(other: Any?): Boolean = when (other) {
            is Utf8 -> bytes.contentEquals(other.bytes)
            is Text -> other == this
            else -> false
        }

        override fun hashCode(): Int = bytes.contentHashCode()
        override fun toString(): String = "Utf8(${bytes.size} bytes)"
    }

    class Array(elements: List<JsonValue>) : JsonValue() {
        val elements: List<JsonValue> = Collections.unmodifiableList(ArrayList(elements))

        override fun equals(other: Any?): Boolean = other is Array && elements == other.elements
        override fun hashCode(): Int = elements.hashCode()
        override fun toString(): String = "Array(${elements.size})"
    }

    /** Members keep the order they were given in. The canonical emitter sorts; equality ignores order. */
    class Object(members: Map<String, JsonValue>) : JsonValue() {
        val members: Map<String, JsonValue> = Collections.unmodifiableMap(LinkedHashMap(members))

        operator fun get(key: String): JsonValue? = members[key]

        override fun equals(other: Any?): Boolean = other is Object && members == other.members
        override fun hashCode(): Int = members.hashCode()
        override fun toString(): String = "Object(${members.size})"
    }

    val isNull: Boolean get() = this === Null

    val boolOrNull: Boolean? get() = (this as? Bool)?.value

    /** Only an [Integer]: a [Real] is never read as an integer. */
    val longOrNull: Long? get() = (this as? Integer)?.value

    /** A [Real], or an [Integer] widened, as Swift's `Value.double` does. */
    val doubleOrNull: Double?
        get() = when (this) {
            is Real -> value
            is Integer -> value.toDouble()
            else -> null
        }

    /**
     * A string's UTF-8 bytes. For [Utf8] this is the value's own array, not a copy. Use
     * this, never [textOrNull], for anything that may be a secret.
     */
    val utf8OrNull: ByteArray?
        get() = when (this) {
            is Utf8 -> bytes
            is Text -> Utf8Codec.encodeStrict(value)
            else -> null
        }

    /** Materialises a `String`. The final hop, and only for values that are plaintext by design. */
    val textOrNull: String?
        get() = when (this) {
            is Text -> value
            is Utf8 -> Utf8Codec.decodeStrict(bytes)
            else -> null
        }

    val arrayOrNull: List<JsonValue>? get() = (this as? Array)?.elements

    val objectOrNull: Map<String, JsonValue>? get() = (this as? Object)?.members

    companion object {
        fun of(value: Boolean): JsonValue = Bool(value)
        fun of(value: Long): JsonValue = Integer(value)
        fun of(value: Int): JsonValue = Integer(value.toLong())
        fun of(value: Double): JsonValue = Real(value)
        fun of(value: String): JsonValue = Text(value)
        fun array(vararg elements: JsonValue): JsonValue = Array(elements.asList())
        fun obj(vararg members: Pair<String, JsonValue>): JsonValue = Object(linkedMapOf(*members))
    }
}
