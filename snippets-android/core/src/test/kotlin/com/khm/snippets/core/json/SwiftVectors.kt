package com.khm.snippets.core.json

import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.Utf8
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Reads the golden vectors the Swift sources emitted (`tools/swift-interop`), from
 * `src/test/resources/vectors/swift/sealed`. A vector file is
 * `{"cases": [{"name": …, "kind": …, …}]}`; the accessors below follow the encodings of
 * that tool's `J` type.
 */
object SwiftVectors {

    /** One case of a vector file. */
    class Case(val file: String, private val fields: JsonObject) {
        val name: String get() = string("name")
        val kind: String get() = string("kind")

        /** For failure messages: which vector to look at. */
        val label: String get() = "$file case $name"

        fun has(key: String): Boolean = key in fields
        fun element(key: String): JsonElement = fields[key] ?: error("$label has no \"$key\"")
        fun isNull(key: String): Boolean = element(key) is JsonNull
        fun string(key: String): String = element(key).jsonPrimitive.content
        fun stringOrNull(key: String): String? = if (isNull(key)) null else string(key)
        fun boolean(key: String): Boolean = element(key).jsonPrimitive.boolean
        fun int(key: String): Int = element(key).jsonPrimitive.int
        fun strings(key: String): List<String> = element(key).jsonArray.map { it.jsonPrimitive.content }
        fun array(key: String): JsonArray = element(key).jsonArray
        fun obj(key: String): Case = Case(file, element(key).jsonObject)
        fun objects(key: String): List<Case> = array(key).map { Case(file, it.jsonObject) }

        /** `J.text`: `{"text": …, "utf8Hex": …}`. The bytes are authoritative. */
        fun text(key: String): String = text(element(key))

        fun texts(key: String): List<String> = array(key).map(::text)

        /** `J.double` / `J.date`: `{"bits": <16 hex digits>, "swift": <description>}`. */
        fun double(key: String): Double = double(element(key))

        /** `J.hex`. */
        fun bytes(key: String): ByteArray = Bytes.fromHex(string(key)) ?: error("$label: \"$key\" is not hex")

        private fun text(element: JsonElement): String {
            val hex = element.jsonObject.getValue("utf8Hex").jsonPrimitive.content
            return Utf8.decodeStrict(Bytes.fromHex(hex) ?: error("$label: bad hex")) ?: error("$label: bad UTF-8")
        }

        companion object {
            fun double(element: JsonElement): Double =
                Double.fromBits(java.lang.Long.parseUnsignedLong(element.jsonObject.getValue("bits").jsonPrimitive.content, 16))
        }
    }

    /** The cases of `<name>.json`. The file must exist: these vectors are part of the test suite. */
    fun cases(name: String): List<Case> {
        val file = "$name.json"
        val stream = SwiftVectors::class.java.getResourceAsStream("/vectors/swift/sealed/$file")
            ?: error("missing vector file $file; run tools/swift-interop/emit.sh")
        val root = stream.bufferedReader(Charsets.UTF_8).use { Json.parseToJsonElement(it.readText()) }.jsonObject
        return root.getValue("cases").jsonArray.map { Case(file, it.jsonObject) }
    }

    fun cases(name: String, kind: String): List<Case> = cases(name).filter { it.kind == kind }
}
