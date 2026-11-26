package com.khm.snippets.core.state

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue

// Editing a decoded JSON document by path, for the strictness tests of both local files.

internal fun parseJson(bytes: ByteArray): JsonValue = CanonicalJson.parse(bytes)

internal fun JsonValue.bytes(): ByteArray = CanonicalJson.encode(this)

/** The object at [path] (keys from the root). */
internal fun JsonValue.objectAt(path: List<String>): Map<String, JsonValue> {
    var value = this
    for (key in path) value = value.objectOrNull!!.getValue(key)
    return value.objectOrNull!!
}

/** A copy with the object at [path] replaced by [change] of it. */
internal fun JsonValue.edited(path: List<String>, change: (MutableMap<String, JsonValue>) -> Unit): JsonValue {
    val members = LinkedHashMap(objectOrNull!!)
    if (path.isEmpty()) {
        change(members)
    } else {
        members[path[0]] = members.getValue(path[0]).edited(path.drop(1), change)
    }
    return JsonValue.Object(members)
}

/** A value of another JSON type than [value]. */
internal fun anotherType(value: JsonValue): JsonValue = when (value) {
    is JsonValue.Text, is JsonValue.Utf8 -> JsonValue.of(7)
    is JsonValue.Integer, is JsonValue.Real -> JsonValue.of("7")
    is JsonValue.Bool -> JsonValue.of("true")
    is JsonValue.Object -> JsonValue.array(JsonValue.of(1))
    is JsonValue.Array -> JsonValue.of(false)
    JsonValue.Null -> JsonValue.of(1)
}

/** Every object path in [value], the root first. */
internal fun objectPaths(value: JsonValue, prefix: List<String> = emptyList()): List<List<String>> {
    val members = value.objectOrNull ?: return emptyList()
    val out = ArrayList<List<String>>()
    out.add(prefix)
    for ((key, member) in members) out.addAll(objectPaths(member, prefix + key))
    return out
}

internal fun dotted(path: List<String>): String = path.joinToString(".")
